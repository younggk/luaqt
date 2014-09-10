-- NOTICE:
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
-- POSSIBILITY OF SUCH DAMAGE.
-- 
-- read COPYRIGHT.md for more informations.

local path = require("path")
local json = require("json")

local function issuperclasstemplate(superclassname)
	local _ ,end_ = string.find(superclassname ,"<%a+>")
	return end_ ~= nil
end
local function readJsonFile(path)
	local fd = io.open(path)
	if (not fd) then
		return 
	end
	local str = fd:read("*a")
	fd:close()
	return json.decode(str)
end

_G.config = readJsonFile(arg[1] or "config.json")

local excludeClasses = {}
for i,v in ipairs(config.excludeClasses) do
	excludeClasses[v] = true
end

local excludedIncludePath = {}
for i,v in ipairs(config.excludedIncludePath) do
	excludedIncludePath[v] = true
end

local noExtendedClass = {}
for i,v in ipairs(config.noExtendedClass) do
	noExtendedClass[v] = true
end

local rootPath = path.dirname(debug.getinfo(1, "S").source:sub(2))

local function loadTemplate(fn)
	local fd = io.open(path.join(rootPath, fn))
	local src = fd:read("*a")
	fd:close()

	return function(args)
		setmetatable(args, {
			__index = _G
		})
		return src:gsub("%/%*%%(.-)%%%*%/", function(s)
			local f = assert(loadstring(s))
			debug.setfenv(f, args)
			return f() or nil
		end) or nil
	end
end

local loadedClassInfo = {}

local function loadClassInfo(class)
	if (loadedClassInfo[class] == nil) then
		loadedClassInfo[class] = readJsonFile("tmp/"..class..".json") or false
	end
	return loadedClassInfo[class]
end

local function getMethodSign(method)
	local ret = {method.name,'(', ''}
	for i,v in ipairs(method.arguments) do
		table.insert(ret, v.normalizedType)
		table.insert(ret, ',')
	end
	table.remove(ret)
	table.insert(ret, ')')
	return table.concat(ret)
end

local function getAbstractMethods(info, map)
	-- first, get all abstract method from all super classes
	map = map or {}
	if  type(info) ~= "table" then return map end;
	if  info.superclassList ~= nil then -- !=
		for i,v in ipairs(info.superclassList) do
			local cinfo = loadClassInfo(v.name) --or error("Cannot find info of "..v.name)
			if cinfo ==nil then return map end
			getAbstractMethods(cinfo, map)
			-- for i,v in ipairs(list or {}) do
				-- map[v] = true
			-- end
		end
	end
	if info.methodList ~= nil then
	-- test if abstract method are implemented.
		for i,v in ipairs(info.methodList) do
			if (not v.isStatic) then
				local sign = getMethodSign(v)
				if (v.isAbstract) then
					map[sign] = true
				else
					map[sign] = nil
				end
			end
		end
	end
	-- local ret = {}
	-- for k,v in pairs(map) do
		-- table.insert(ret, k)
	-- end
	return map
end

local function isDerivedFromQObject(info)
	if (info.classname == "QObject") then
		return true
	end
	for i,v in ipairs(info.superclassList) do
		local cinfo = loadClassInfo(v.name)
		if (cinfo and isDerivedFromQObject(cinfo)) then
			return true
		end
	end
	return false
end

local function isAbstractClass(info)
	local am = getAbstractMethods(info)
	return next(am) and true
end

local packageTemplate = loadTemplate("template/package.cpp")
local function writePackageSource(packageName, classes)
	local fd = io.open("gen/"..packageName.."/"..packageName..".cpp", "w+")

	fd:write(packageTemplate({
			packageName = packageName,
			classes = classes
		}))
	fd:close()
end

local priTemplate = loadTemplate("template/package.pri")
local function writePri(packageName, classes)
	local fd = io.open("gen/"..packageName.."/"..packageName..".pri", "w+")
	fd:write(priTemplate({
			packageName = packageName,
			classes = classes
		}))
	fd:close()
end

local function copyTable(table)
	local ret = {}

	for k,v in pairs(table) do
		if (type(v) == 'table') then
			ret[k] = copyTable(v)
		else
			ret[k] = v
		end
	end
	return ret
end

local function findNestedName(class, name)
	-- find nested enum
	if type(class) ~="table" then
		print("Cannot find nested name")
		return name
	end
	for i,v in ipairs(class.enumList) do
		if (v.name == name) then
			return class.classname.."::"..name
		end
	end
	-- find nested class
	for i,v in ipairs(class.nestedClasses) do
		if (v.classname == name) then
			return class.classname.."::"..name
		end
	end
	-- find flag alias
	for k,v in pairs(class.flagAliases) do
		if (v == name) then
			return class.classname.."::"..name
		end
	end
	for i ,v in pairs(class.typedef) do
		if(v.name == name) then
			return class.classname.."::"..name
		end
	end
	-- find in super classes.
	for i,v in ipairs(class.superclassList) do
		local cinfo = loadClassInfo(v.name)
		local ret = findNestedName(cinfo, name)
		if (ret) then
			return ret
		end
	end
end

local function parseNestedName(class, name)
	return name:gsub("(%:*)(%w*%_*%w+)", function(d, s)
		if (d == "::") then
			return
		end
		return findNestedName(class, s)
	end)
end

local methodTemplates = {}
local methodOLTemplates = {}

methodTemplates.constructor = loadTemplate("template/constructor.cpp")
methodOLTemplates.constructor = loadTemplate("template/constructorol.cpp")
methodTemplates.method = loadTemplate("template/method.cpp")
methodOLTemplates.method = loadTemplate("template/methodol.cpp")
methodTemplates.extended = loadTemplate("template/constructorext.cpp")
methodOLTemplates.extended = loadTemplate("template/constructorextol.cpp")
methodTemplates.static = loadTemplate("template/staticmethod.cpp")
methodOLTemplates.static = loadTemplate("template/staticmethodol.cpp")

local function printMethods(class, catalog, name, methods)
	local template = methodTemplates[catalog]
	local overloadTemplate = methodOLTemplates[catalog]
	-- local template = isConstructor and constructorTemplate or methodTemplate
	-- local overloadTemplate = isConstructor and constructorOLTemplate or methodOLTemplate

	do
		local genMethods = {}

		for i,v in ipairs(methods) do
			table.insert(genMethods, copyTable(v))
			while (#v.arguments >0 and v.arguments[#v.arguments].isDefault) do
				v = copyTable(v)
				table.remove(v.arguments)
				table.insert(genMethods, v)
			end
		end

		methods = genMethods
	end

	-- parse nested enum&class argument
	do
		for i,v in ipairs(methods) do
			for j,arg in ipairs(v.arguments) do
				arg.normalizedType = parseNestedName(class, arg.normalizedType)
			end
		end
	end

	local function overloads()
		local ret = {}
		for i,v in ipairs(methods) do
			v.normalizedType = parseNestedName(class, v.normalizedType)
			table.insert(ret, overloadTemplate(v))
		end
		return table.concat(ret, '\n');
	end

	return template({
			name = name,
			class = class,
			methods = methods,
			overloads = overloads
		})
end

local funcs = {}

function funcs:constructors()
	return printMethods(self, "constructor", self.classname..'_constructor', self.constructorList)
end

local extendedImpl = loadTemplate("template/extendedimpl.cpp")
local extendedImplOl = loadTemplate("template/extendedimplol.cpp")
function funcs:extendedImpl()
	if (noExtendedClass[self.classname]) then
		return ""
	end
	local function constructorOverloads()
		local methods = self.constructorList

		do
			local genMethods = {}
			for i,v  in ipairs(methods) do
				table.insert(genMethods, copyTable(v))
				while (#v.arguments >0 and v.arguments[#v.arguments].isDefault) do
					v = copyTable(v)
					table.remove(v.arguments)
					table.insert(genMethods, v)
				end
			end
			methods = genMethods
		end
		do
			for i,v in ipairs(methods) do
				for j,arg in ipairs(v.arguments) do
					arg.type.rawName = parseNestedName(self, arg.type.rawName)
				end
			end
		end

		local ret = {}
		for i,v in ipairs(methods) do
			table.insert(ret, extendedImplOl({
				class = self,
				func = v,
			}))
		end
		return table.concat(ret, '\n');
	end
	return extendedImpl({
			class = self,
			constructorOverloads = constructorOverloads
		})
end

local constructorext_noext = loadTemplate("template/constructorext_noext.cpp")
function funcs:extendedConstructor()
	if (noExtendedClass[self.classname]) then
		return constructorext_noext({
				name = self.classname..'_constructorWithExtend'
			})
	end
	return printMethods(self, "extended", self.classname..'_constructorWithExtend', self.constructorList)
end

local function getMethodNames(self, isStatic)
	isStatic = isStatic or false
	local ret = {}
	local operators = {}
	for i, v in ipairs(self.methodList) do
		if (v.access == "public" and v.isStatic == isStatic) then
			local tmp = ret
			if (v.name:sub(1, 9) == "operator ") then
				tmp = operators
			end
			if (tmp[v.name] and v.isStatic == isStatic) then
				table.insert(tmp[v.name], v)
			else
				tmp[v.name] = {v}
			end
		end
	end
	if (not isStatic) then
		for i, v in ipairs(self.slotList) do
			if (v.access == "public") then
				local tmp = ret
				if (v.name:sub(1, 9) == "operator ") then
					tmp = operators
				end
				if (tmp[v.name]) then
					table.insert(tmp[v.name], v)
				else
					tmp[v.name] = {v}
				end
			end
		end
		for i, v in ipairs(self.signalList) do
			if (v.access == "public") then
				local tmp = ret
				if (v.name:sub(1, 9) == "operator ") then
					tmp = operators
				end
				if (tmp[v.name]) then
					table.insert(tmp[v.name], v)
				else
					tmp[v.name] = {v}
				end
			end
		end
	end
	return ret
end

local function getExcludedMethods(self)
	local excludedMethods = config.excludedMethods[self.classname]
	if (not excludedMethods) then
		return {}
	end
	local ret = {}
	for i,v in ipairs(excludedMethods) do
		ret[v] = true
	end
	return ret
end

local function getExcludedSignals(self)
	local excludedSignals = config.excludedSignals[self.classname]
	if (not excludedSignals) then
		return {}
	end
	local ret = {}
	for i,v in ipairs(excludedSignals) do
		ret[v] = true
	end
	return ret
end

local function getExcludedEnums(self)
	local excludedEnums = config.excludedEnums[self.classname]
	if (not excludedEnums) then
		return {}
	end
	local ret = {}
	for i,v in ipairs(excludedEnums) do
		ret[v] = true
	end
	return ret
end

function funcs:methodImpls()
	local ret = {}
	local methods = getMethodNames(self)
	local excludedMethods = getExcludedMethods(self)
	for k,v in pairs(methods) do
		if (not excludedMethods[k]) and issuperclasstemplate(k)==false and v[1].isFriend == false then
			table.insert(ret, printMethods(self, "method", self.classname..'_'..k, v))
		end
	end
	return table.concat(ret, '\n')
end

function funcs:declareExtraMethods()
	local ret = {}
	local methods = config.extraMethods[self.classname] or {}
	for i,v in ipairs(methods) do
		table.insert(ret, string.format("int %s_%s(lua_State *L);", self.classname, v))
	end
	return table.concat(ret, '\n')
end

function funcs:methodTable()
	local ret = {}
	local methods = getMethodNames(self)
	local excludedMethods = getExcludedMethods(self)
	for k,v in pairs(methods) do
		if (not excludedMethods[k]) and issuperclasstemplate(k)==false and v[1].isFriend == false then
			table.insert(ret, '\t{"'..k..'", '..self.classname..'_'..k..'},\n')
		end
	end
	for i,k in pairs(config.extraMethods[self.classname] or {}) do
		table.insert(ret, '\t{"'..k..'", '..self.classname..'_'..k..'},\n')
	end
	return table.concat(ret)
end

function funcs:staticMethodsImpls()
	local ret = {}
	local methods = getMethodNames(self, true)
	local excludedMethods = getExcludedMethods(self)
	for k,v in pairs(methods) do
		if (not excludedMethods[k]) then
			table.insert(ret, printMethods(self, "static", self.classname..'_static_'..k, v))
		end
	end
	return table.concat(ret, '\n')
end

function funcs:staticMethodsTable()
	local ret = {}
	local methods = getMethodNames(self, true)
	local excludedMethods = getExcludedMethods(self)
	for k,v in pairs(methods) do
		if (not excludedMethods[k]) then
			table.insert(ret, '\t{"'..k..'", '..self.classname..'_static_'..k..'},\n')
		end
	end
	return table.concat(ret)
end

function signalName(self)
	local args = {}
	for i,v in ipairs(self.arguments) do
		table.insert(args, v.type.rawName)
	end

	return string.format("2%s(%s)", self.name, table.concat(args, ", "))
end

local signalTemplate = loadTemplate("template/signalimpl.cpp")
function funcs:signalImpls()
	local ret = {}
	local excludes = getExcludedSignals(self)
	
	for i,v in ipairs(self.signalList) do
		if (not v.isPrivateSignal) then
			v = copyTable(v)
			local name = signalName(v)
			if (excludes[name] or excludes[v.name]) then
			else
				v.id = i
				v.class = self
				v.type.rawName = parseNestedName(self, v.type.rawName)
				for i,arg in ipairs(v.arguments) do
					arg.type.rawName = parseNestedName(self, arg.type.rawName)
				end
				table.insert(ret, signalTemplate(v))
			end
		end
	end
	return table.concat(ret, '\n')
end

function funcs:signalTable()
	local ret = {}
	local excludes = getExcludedSignals(self)

	for i,v in ipairs(self.signalList) do
		if (not v.isPrivateSignal) then
			v = copyTable(v)
			local name = signalName(v)
			if (excludes[name] or excludes[v.name]) then
			else
				table.insert(ret, string.format('\t{"%s", signal_%s_%d},', name, self.classname, i))
				while (#v.arguments>0 and table.remove(v.arguments).isDefault) do
					table.insert(ret, string.format('\t{"%s", signal_%s_%d},', signalName(v), self.classname, i))
				end
			end
		end
	end
	return table.concat(ret, '\n')
end

function funcs:depHeaders()
	local classes = {}
	for i,v in ipairs(self.constructorList) do
		for j,arg in ipairs(v.arguments) do
			for type in arg.type.rawName:gmatch("%w+") do
				classes[type] = true
			end
		end
	end
	for i,v in ipairs(self.methodList) do
		for j,arg in ipairs(v.arguments) do
			for type in arg.type.rawName:gmatch("%w+") do
				classes[type] = true
			end
		end
		for type in v.type.rawName:gmatch("%w+") do
			classes[type] = true
		end
	end
	local ret = {}
	local mark = {}
	for k,v in pairs(classes) do
		local cinfo = loadClassInfo(k)
		local fn = cinfo and cinfo.fileName:gsub("%\\", "/")
		if (cinfo and fn and not mark[fn] and not excludedIncludePath[fn]) then
			mark[fn] = true
			table.insert(ret, string.format("#include <%s>\n", fn))
		end

		fn = config.classIncludePath[k]
		if (fn and not mark[fn]) then
			mark[fn] = true
			table.insert(ret, string.format("#include <%s>\n", fn))
		end
	end
	return table.concat(ret)
end

local casterTemplate = loadTemplate("template/caster.cpp")
function generateCasters(self, ret, route)
	if (#route > 1) then
		table.insert(ret, casterTemplate({
				route = route,
				class = self,
			}))
	end
	if type( self ) ~="table" then return end
	for i,v in ipairs(self.superclassList) do
		if (v.access == "public" and issuperclasstemplate( v.name )==false) then
			table.insert(route, v.name)
			generateCasters(loadClassInfo(v.name), ret, route)
			table.remove(route)
		end
	end
end

function generateCasterList(self, ret, route)
	if (#route > 1) then
		table.insert(ret, string.format(
				'\t{"%s", %s},\n'
			, route[#route], table.concat(route, '_')))
	end
	if type(self ) ~= "table" then return end
	for i,v in ipairs(self.superclassList) do
		if (v.access == "public" and issuperclasstemplate( v.name )==false)  then
			table.insert(route, v.name)
			generateCasterList(loadClassInfo(v.name), ret, route)
			table.remove(route)
		end
	end
end

function funcs:casters()
	local ret = {}
	generateCasters(self, ret, {self.classname})
	return table.concat(ret)
end

function funcs:casterList()
	local ret = {}
	generateCasterList(self, ret, {self.classname})
	return table.concat(ret)
end

function funcs:declareInitSuperMethods()
	local ret = {}
	for i = #self.superclassList, 1, -1 do
		if (self.superclassList[i].access == "public") and issuperclasstemplate(self.superclassList[i].name)==false then
			table.insert(ret, string.format("void %s_initMethods(lua_State *L);\n", self.superclassList[i].name))
		end
	end
	return table.concat(ret)
end

function funcs:initSuperMethods()
	local ret = {}
	for i = #self.superclassList, 1, -1 do
		if (self.superclassList[i].access == "public") then
			if issuperclasstemplate ( self.superclassList[i].name) ==false then
				table.insert(ret, string.format("\t%s_initMethods(L);\n", self.superclassList[i].name))
			end
		end
	end
	return table.concat(ret)
end

function funcs:enumValues()
	local ret = {}
	local excluded = getExcludedEnums(self)
	for i,v in ipairs(self.enumList) do
		if (not excluded[v.name]) then
			if( v.access =="public" ) then
				table.insert(ret, string.format("\t/* %s::%s */\n", self.classname, v.name))
				for j,n in ipairs(v.values) do
					table.insert(ret, string.format(
						'\t{"%s", (int)%s::%s},\n', n, self.classname, n
						))
				end
			end
		end
	end
	return table.concat(ret)
end

local classTemplate = loadTemplate("template/class.cpp")
local function writeClassSource(packageName, class)
	class.isAbstract = isAbstractClass(class)
	class = copyTable(class)
	for k,v in pairs(funcs) do
		class[k] = class[k] or function(...)
			return v(class, ...)
		end
	end

	local fd = io.open("gen/"..packageName.."/def"..class.classname..".cpp", "w+")
	fd:write(classTemplate(class))
	fd:close()
end

print("reading class info")
local packages = readJsonFile("tmp/classList.json")

for k,classes in pairs(packages) do
	print('Package: '..k)
	local pkgdir = "gen/"..k
	path.mkdir(pkgdir)
	local validClasses = {}
	for i,class in ipairs(classes) do
		print('\tClass: '..class)
		local info = (not excludeClasses[class]) and loadClassInfo(class)
		-- if (info.hasQObject and not isDerivedFromQObject(info)) then
			-- print("Warning: hasQObject but not derived from QObject.")
		-- end
		--assert(info.classname=="Qt" or (not info.hasQObject) or isDerivedFromQObject(info))
		if (excludeClasses[class]) then
			print("\t\tExcluded.")
		elseif (info and info.hasQObject and info.name ~= "Qt") then
		-- else
			writeClassSource(k, info)
			table.insert(validClasses, class)
		else
			print('\t\tIgnore non-QObject type.')
		end
		-- collectgarbage()
	end
	writePackageSource(k, validClasses)
	writePri(k, validClasses)
end
