--!strict
--@author: crusherfire
--@date: 11/11/24
--[=[
	@class Logger
	Creates a logger object that can print, warn, assert, and error with a
	formatted prefix. By default, :print() is suppressed on live servers.
]=]

local RunService = game:GetService("RunService")

type self = {
	_prefix            : string,
	_printsOnProduction : boolean,
}

local Logger = {}
local MT     = {}
MT.__index   = MT

export type LoggerType = typeof(setmetatable({} :: self, MT))

--[=[
	Constructs a new Logger with the given prefix.

	@param prefix           string   -- The tag shown in every log message.
	@param withBrackets     boolean? -- Wrap the prefix in brackets. Defaults to `true`.
	@param printsOnProduction boolean? -- Allow :print() on live servers. Defaults to `false`.
	@return LoggerType
]=]
function Logger.new(prefix: string, withBrackets: boolean?, printsOnProduction: boolean?): LoggerType
	assert(typeof(prefix) == "string", "Expected string for prefix.")
	local self = setmetatable({} :: self, MT)
	local brackets = if typeof(withBrackets) ~= "nil" then withBrackets else true
	self._prefix             = if brackets then `[{prefix}]:` else `{prefix}:`
	self._printsOnProduction = printsOnProduction or false
	return self
end

--[=[
	Returns whether `object` was created by this Logger class.

	@param object any -- The object to check.
	@return boolean
]=]
function Logger:BelongsToClass(object: any): boolean
	assert(typeof(object) == "table", "Expected table for object!")
	return getmetatable(object).__index == MT
end

--[=[
	Prints a message. Suppressed on live servers unless `printsOnProduction` was set.

	@param msg       any      -- The message to print.
	@param traceback boolean? -- Append a full stack traceback.
]=]
function MT.print(self: LoggerType, msg: any, traceback: boolean?)
	if not RunService:IsStudio() and not self._printsOnProduction then return end
	print(self._prefix, msg, if traceback then `\n{debug.traceback()}` else "")
end

--[=[
	Emits a warning with the logger prefix.

	@param msg       any      -- The warning message.
	@param traceback boolean? -- Append a full stack traceback.
]=]
function MT.warn(self: LoggerType, msg: any, traceback: boolean?)
	warn(self._prefix, msg, if traceback then `\n{debug.traceback()}` else "")
end

--[=[
	Calls :error() if `expression` is falsy.

	@param expression any      -- The value to test.
	@param err        any      -- The error message if the assertion fails.
	@param traceback  boolean? -- Append a full stack traceback to the error.
]=]
function MT.assert(self: LoggerType, expression: any, err: any, traceback: boolean?)
	if not expression then
		self:error(err, traceback)
	end
end

--[=[
	Like :assert(), but only formats the error string when the expression fails,
	avoiding unnecessary string concatenation in hot paths.

	@param expression any      -- The value to test.
	@param traceback  boolean? -- Append a full stack traceback.
	@param toFormat   string   -- A `string.format` template for the error message.
	@param ...        string   -- Values to insert into `toFormat`.
]=]
function MT.assertFormatted(self: LoggerType, expression: any, traceback: boolean?, toFormat: string, ...: string)
	if not expression then
		self:error(string.format(toFormat, ...), traceback)
	end
end

--[=[
	Emits a warning (instead of an error) when `expression` is falsy.

	@param expression any      -- The value to test.
	@param msg        any      -- The warning message if the assertion fails.
	@param traceback  boolean? -- Append a full stack traceback.
]=]
function MT.assertWarn(self: LoggerType, expression: any, msg: any, traceback: boolean?)
	if not expression then
		self:warn(msg, traceback)
	end
end

--[=[
	Raises a Lua error with the logger prefix prepended.

	@param err       any      -- The error message or value.
	@param traceback boolean? -- Append a full stack traceback.
]=]
function MT.error(self: LoggerType, err: any, traceback: boolean?)
	error(`{self._prefix} {err}{if traceback then `\n{debug.traceback()}` else ""}`)
end

--[=[
	Destroys the Logger instance and clears its metatable.
]=]
function MT.Destroy(self: LoggerType)
	setmetatable(self :: any, nil)
	table.clear(self :: any)
end

return Logger
