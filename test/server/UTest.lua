--------------------------------------------------------------------------------
-- UTest.lua
-- @version 0.1.0
--------------------------------------------------------------------------------

type Array<T> = {[number]: T}
type TestCase = {
    Name: string;
    Result: boolean;
}

local activeTestName: string?
local activeCase: TestCase?
local cases: Array<TestCase> = {}

local function displayLastTestResults()
    local pass: boolean = true
    local s: string = (activeTestName :: string) .. "\n"
    for _, case: TestCase in cases do
        s ..= string.format("    [%s] %s\n", case.Result and "PASS" or "FAIL", case.Name)
        pass = pass and case.Result
    end
    (pass == true and print or warn::any)(s)
end

local function TEST(name: string)
    if type(name) ~= "string" then error("Test name must be a string", 2) end
    if activeTestName then
        if activeCase then
            table.insert(cases, activeCase)
            activeCase = nil
            displayLastTestResults()
            table.clear(cases)
        else
            error(string.format("%s had no test cases", activeTestName), 2)
        end
    end
    activeTestName = name
end

local function CASE(name: string)
    if type(name) ~= "string" then error("Case name must be a string", 2) end
    if activeTestName == nil then error("No active tests", 2) end
    table.insert(cases, activeCase :: TestCase)
    activeCase = {
        Name = name,
        Result = true
    }
end

local function CHECK(value: any)
    if activeCase == nil then error("No active cases", 2) end
    local case: TestCase = activeCase :: TestCase
    case.Result = case.Result and value
end

return function()
    return TEST, CASE, CHECK
end