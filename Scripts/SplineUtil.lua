Spline = class( nil)

function Spline.init(self)
	print("spline init")
	return self
end
--!
--  	Smooth curves on canvas version 1.3
--
--		By Ken Fyrstenberg Nilsen (c) 2013
--		Abdias Software, http:--abdiassoftware.com/
--
--		Uses an array of points (x,y) to return an array containing points
--		for a smooth curve.
--
--	USAGE:
--
--		getCurvePoints(points, tension, numberOfSegments)
--
--		getCurvePoints(array)
--		getCurvePoints(array, float)
--		getCurvePoints(array, float, boolean)
--		getCurvePoints(array, float, boolean, integer)
--
--		points				= array of float or integers arranged as x1,y1,x2,y1,...,xn,yn. Minimum 2 points.
--		tension				= 0-1, 0 = no smoothing, 0.5 = smooth (default), 1 = very smoothed
--		numberOfSegments	= resolution of the smoothed curve. Higer number -> smoother (default 16)
--
--		NOTE: array must contain a minimum set of two points.
--		Known bugs: closed curve draws last point wrong.
--

function Spline.getCurvePoints(self,ptsa, tension, numOfSegments)
	--print('getcurvepoints',#ptsa,tension,numOfSegments)
	-- use input value if provided, or use a default value	 
	tension = (tension or 0.5)
	numOfSegments = (numOfSegments or 16)

	local _pts
    local res = {}			--/ clone array
	local x
    local y					--/ our x,y coords
    local t1x
    local t2x
    local t1y
    local t2y		--/ tension vectors
	local c1, c2, c3, c4			--/ cardinal points
	local st, t, i				--/ steps based on num. of segments
	local pow3, pow2				--/ cache powers
	local pow32, pow23
	local p0, p1, p2, p3			--/ cache points
	local pl = #ptsa

	--/ clone array so we don't change the original content
	local _pts = {}
    for k, v in ipairs(ptsa) do
		--print('setting k,v',k,v)
        _pts[k] = v
    end
	
	--print("inserting",ptsa[2])
    table.insert(_pts, 1, ptsa[2]) -- table gets mutated wrong
    table.insert(_pts, 1, ptsa[1])
    table.insert(_pts, ptsa[pl - 1])
    table.insert(_pts, ptsa[pl - 0])
	--/ 1. loop goes through point array
	--/ 2. loop goes through each segment between the two points + one point before and after
	----for (i = 2 i < pl i += 2)
    for i=3, pl, 2 do
		p0 = _pts[i]
		p1 = _pts[i + 1]
		p2 = _pts[i + 2]
		p3 = _pts[i + 3]

		--/ calc tension vectors
		t1x = (p2 - _pts[i - 2])* tension
		t2x = (_pts[i + 4] - p0)* tension

		t1y = (p3 - _pts[i - 1])* tension
		t2y = (_pts[i + 5] - p1) * tension

        for t=0, numOfSegments do

			--/ calc step
			st = t / numOfSegments
		
			pow2 = math.pow(st, 2)
			pow3 = pow2 * st
			pow23 = pow2 * 3
			pow32 = pow3 * 2

			--/ calc cardinals
			c1 = pow32 - pow23 + 1 
			c2 = pow23 - pow32
			c3 = pow3 - 2 * pow2 + st
			c4 = pow3 - pow2

			--/ calc x and y cords with common control vectors
			x = c1 * p0 + c2 * p2 + c3 * t1x + c4 * t2x
			y = c1 * p1 + c2 * p3 + c3 * t1y + c4 * t2y
		
			--/ store points in array
            table.insert(res, x)
            table.insert(res, y)
		end
	end
	
	return res
end

-- Example running
function demo_spline()
	print('running demo')
	local points = {}
	local prevX = 0
	local prevY = 0
	for i=1, 10 do
		local x = prevX + math.random(1,10)
		local y = prevY + math.random(1,10)

		table.insert(points, x)
		table.insert(points, y)
		prevX = x
		prevY = y
	end
	for i=1, #points, 2 do
		print(points[i]..","..points[i+1])
	end

	local spline = Spline()
	local res = spline:getCurvePoints(points)
	--print(#res)
	for i=1, #res, 2 do
		print(res[i]..","..res[i+1])
	end
end

--demo_spline()
