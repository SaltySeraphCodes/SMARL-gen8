Timer = class( nil ) -- TImer 2.0

function Timer.start( self, ticks )
	self.ticks = ticks or 0
	self.count = 0
end

function Timer.reset( self )
	self.ticks = self.ticks or -1
	self.count = 0
end

function Timer.stop( self )
	self.ticks = -1
	self.count = 0
end

function Timer.tick( self )
	self.count = self.count + 1
end

function Timer.status(self)
	return self.count 
end

function Timer.remaining(self)
	return self.ticks-self.count
end

function Timer.done( self )
	return self.ticks >= 0 and self.count >= self.ticks
end
