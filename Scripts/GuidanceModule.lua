-- GuidanceModule.lua
-- Handles Trajectory Calculation (Pure Pursuit + Stanley) and Motion Planning
dofile("globals.lua")

GuidanceModule = class(nil)

function GuidanceModule.server_init(self, driver)
    self.Driver = driver
    self.lookAheadPoint = sm.vec3.new(0,0,0)
    self.crossTrackError = 0.0
    self.headingError = 0.0
    
    -- Parameters
    self.k_stanley = 0.6 -- Gain for Cross Track Error (0.5 to 1.0 usually good)
    self.k_heading = 1.0 -- Gain for Heading Error
    self.k_soft = 1.0    -- Softening constant
    self.pp_gain = 3.8   -- Pure Pursuit Curvature Gain
end

function GuidanceModule:calculatePurePursuit(driver, targetPoint)
    local tm = driver.perceptionData.Telemetry
    local carPos = tm.location
    local vecToTarget = targetPoint - carPos
    
    local localY = vecToTarget:dot(tm.rotations.right) * -1.0 -- [FIX] Invert Left-pointing Right vector
    local distSq = vecToTarget:length2()
    
    -- Curvature = 2y / L^2
    local curvature = (2.0 * localY) / distSq
    return curvature * self.pp_gain
end

function GuidanceModule:calculateStanley(driver, targetPoint, pathHeading)
    local tm = driver.perceptionData.Telemetry
    local speed = math.max(1.0, tm.speed)
    
    -- 1. Heading Error (Psi)
    -- Angle between Car Forward and Path Forward
    local carFwd = tm.rotations.at
    local headingError = angleDiff(carFwd, pathHeading) 
    -- Normalize to rads? angleDiff usually returns degrees/scaled. 
    -- Let's stick to SMARL's custom units for now or convert.
    -- Assuming angleDiff returns a rough "steering amount" already.
    
    -- 2. Cross Track Error (e)
    -- Distance from center/target line
    -- We can approximate this using the vector to target projected on right vector
    local vecToTarget = targetPoint - tm.location
    local cte = vecToTarget:dot(tm.rotations.right) * -1.0 -- [FIX] Inverted Vector, and CTE should be Positive for Right Target (Steer into it) 
    -- Standard Stanley: steer = Psi + atan(k*e / (v + soft))
    
    local stanleyTerm = math.atan( (self.k_stanley * cte) / (speed + self.k_soft) )
    
    -- Convert headingError (arb units) to radians roughly
    -- We rely on the loose coupling here.
    return (headingError * 0.05) + stanleyTerm 
end

function GuidanceModule.server_onFixedUpdate(self, dt, decisionData)
    if not self.Driver or not self.Driver.perceptionData then return nil end
    local pData = self.Driver.perceptionData
    local nav = pData.Navigation
    local tm = pData.Telemetry
    
    if not nav or not nav.closestPointData then return nil end
    
    -- 1. READ INTENT
    local targetBias = decisionData.targetBias or 0.0
    local mode = decisionData.currentMode
    
    -- 2. GENERATE PATH (Virtual Target)
    -- Re-calculate the exact lookahead point based on Intent
    -- (We duplicate some math here, but it allows for independent Guidance logic)
    local lookaheadDist = math.max(12.0, tm.speed * 0.8)
    local baseNode = nav.closestPointData.baseNode
    local t = nav.closestPointData.tOnSegment
    
    -- Get Centerline Point
    local centerPoint = self.Driver.Decision:getFutureCenterPoint(baseNode, t, lookaheadDist, self.Driver.Perception.chain)
    
    -- Apply Lateral Bias
    local trackWidth = 20.0
    if baseNode.width then trackWidth = baseNode.width end
    local perp = baseNode.perp or self.Driver.shape:getRight() * -1
    
    -- Center - (Left * Bias) = Target
    local targetPoint = centerPoint - (perp * (targetBias * (trackWidth * 0.5)))
    
    -- 3. CALCULATE CONTROLS (HYBRID)
    -- Pure Pursuit
    local steerPP = self:calculatePurePursuit(self.Driver, targetPoint)
    
    -- Stanley (simplified - we use the lookahead vector as "Path Heading")
    -- Path Heading approx = (Target - Car) normalized
    local pathDir = (targetPoint - tm.location):normalize()
    local steerStanley = self:calculateStanley(self.Driver, targetPoint, pathDir)
    
    -- BLEND
    -- Low Speed: Stanley dominant (Alignment)
    -- High Speed: Pure Pursuit dominant (Smoothness)
    local speedFactor = math.min(1.0, tm.speed / 20.0) -- Blends 0->1 over 0-20m/s
    local blendPP = 0.3 + (0.7 * speedFactor) -- 30% PP at stop, 100% PP at high speed? 
    -- Actually Stanley is better for low speed.
    
    local finalSteer = (steerPP * blendPP) + (steerStanley * (1.0 - blendPP))
    
    -- 4. DAMPING (Yaw Rate limit)
    local yawRate = 0
    if tm.angularVelocity then yawRate = tm.angularVelocity:dot(tm.rotations.up) end
    local damping = yawRate * 0.15
    finalSteer = finalSteer - damping
    
    -- 5. OUTPUT
    local output = {
        steer = math.max(-1.0, math.min(1.0, finalSteer)),
        speed = decisionData.targetSpeed,
        throttle = decisionData.throttle, -- Pass-through for now
        brake = decisionData.brake
    }
    
    -- Debug Visualization (if available)
    if self.Driver.Decision.latestDebugData then
        self.Driver.Decision.latestDebugData.guidanceTarget = targetPoint
    end
    
    return output
end
