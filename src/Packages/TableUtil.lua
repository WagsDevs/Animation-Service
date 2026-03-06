--!strict
-- TableUtil (subset used by AnimationService)
-- Full credit: Stephen Leitnick

local TableUtil = {}

local function Copy<T>(t: T, deep: boolean?): T
	if not deep then return (table.clone(t :: any) :: any) :: T end
	local function deepCopy(object: any)
		local newObject = setmetatable({}, getmetatable(object))
		for index: any, value: any in object do
			newObject[index] = if typeof(value) == "table" then deepCopy(value) else value
		end
		return newObject
	end
	return deepCopy(t :: any) :: T
end

function TableUtil.reconcile<S, T>(src: S, template: T): S & T
	assert(type(src)      == "table", "First argument must be a table")
	assert(type(template) == "table", "Second argument must be a table")
	local tbl = table.clone(src)
	for k, v in template do
		local sv = src[k]
		if sv == nil then
			tbl[k] = if type(v) == "table" then Copy(v, true) else v
		elseif type(sv) == "table" then
			tbl[k] = if type(v) == "table" then TableUtil.reconcile(sv, v) else Copy(sv, true)
		end
	end
	return (tbl :: any) :: S & T
end

function TableUtil.copy<T>(t: T, deep: boolean?): T
	return Copy(t, deep)
end

return TableUtil
