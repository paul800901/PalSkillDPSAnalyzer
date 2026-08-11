local M = {}
local hud_strings = require("./hud_strings")

local locale_modules = {
    ["en"] = "./locales/en",
    ["zh-CN"] = "./locales/zh-CN",
    ["zh-TW"] = "./locales/zh-TW",
    ["ja"] = "./locales/ja",
    ["fr"] = "./locales/fr",
    ["it"] = "./locales/it",
    ["de"] = "./locales/de",
    ["es-ES"] = "./locales/es-ES",
    ["pt-BR"] = "./locales/pt-BR",
    ["ru"] = "./locales/ru",
    ["ko"] = "./locales/ko",
    ["id"] = "./locales/id",
    ["es-419"] = "./locales/es-419",
    ["th"] = "./locales/th",
    ["tr"] = "./locales/tr",
    ["vi"] = "./locales/vi",
    ["pl"] = "./locales/pl",
}

local aliases = {
    english = "en",
    schinese = "zh-CN",
    tchinese = "zh-TW",
    japanese = "ja",
    french = "fr",
    italian = "it",
    german = "de",
    spanish = "es-ES",
    brazilian = "pt-BR",
    russian = "ru",
    koreana = "ko",
    korean = "ko",
    indonesian = "id",
    latam = "es-419",
    thai = "th",
    turkish = "tr",
    vietnamese = "vi",
    polish = "pl",
}

local function normalize_language(value)
    local raw = tostring(value or ""):gsub("_", "-")
    local lower = raw:lower()
    if lower == "" or lower == "auto" then
        return nil
    end
    if aliases[lower] ~= nil then
        return aliases[lower]
    end
    if lower == "zh" or lower:find("^zh%-hans") or lower:find("^zh%-cn")
        or lower:find("^zh%-sg") then
        return "zh-CN"
    end
    if lower:find("^zh%-hant") or lower:find("^zh%-tw")
        or lower:find("^zh%-hk") or lower:find("^zh%-mo") then
        return "zh-TW"
    end
    if lower:find("^pt%-br") then
        return "pt-BR"
    end
    if lower:find("^es%-419") or lower:find("^es%-mx")
        or lower:find("^es%-ar") or lower:find("^es%-cl")
        or lower:find("^es%-co") or lower:find("^es%-pe") then
        return "es-419"
    end
    if lower:find("^es") then
        return "es-ES"
    end
    local primary = lower:match("^([a-z][a-z])")
    if primary ~= nil and locale_modules[primary] ~= nil then
        return primary
    end
    return nil
end

local function load_locale(code)
    local module_path = locale_modules[code]
    if module_path == nil then
        return nil
    end
    local ok, locale = pcall(require, module_path)
    if ok and type(locale) == "table" and type(locale.strings) == "table" then
        return locale
    end
    return nil
end

local function interpolate(template, values)
    values = values or {}
    return (tostring(template):gsub("{([%w_]+)}", function(key)
        local value = values[key]
        if value == nil then
            return "{" .. key .. "}"
        end
        return tostring(value)
    end))
end

function M.normalize(value)
    return normalize_language(value)
end

function M.supported_languages()
    local result = {}
    for code in pairs(locale_modules) do
        result[#result + 1] = code
    end
    table.sort(result)
    return result
end

function M.language_options()
    local result = {}
    for index, code in ipairs(hud_strings.language_options) do
        result[index] = code
    end
    return result
end

function M.language_name(code)
    return hud_strings.language_name(code)
end

function M.new(requested_language, detector)
    local code = normalize_language(requested_language)
    if code == nil and type(detector) == "function" then
        local ok, detected = pcall(detector)
        if ok then
            code = normalize_language(detected)
        end
    end
    code = code or "en"

    local english = load_locale("en")
    local locale = load_locale(code) or english
    local translator = {
        code = locale and locale.code or "en",
        requested = requested_language,
    }

    function translator:text(key, values)
        local template = locale and locale.strings[key] or nil
        if template == nil then
            template = hud_strings.get(translator.code, key)
        end
        if template == nil and english ~= nil then
            template = english.strings[key]
        end
        if template == nil then
            return tostring(key)
        end
        return interpolate(template, values)
    end

    function translator:override(value)
        if type(value) ~= "table" then
            return value
        end
        return value[self.code] or value.en or value.default
    end

    return translator
end

return M
