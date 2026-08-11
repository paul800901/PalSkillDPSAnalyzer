package.path = "../Scripts/?.lua;" .. package.path

local localization = require("./localization")
local codes = {
    "en", "zh-CN", "zh-TW", "ja", "fr", "it", "de", "es-ES", "pt-BR",
    "ru", "ko", "id", "es-419", "th", "tr", "vi", "pl",
}

local english = require("./locales/en")
local english_key_count = 0
for _ in pairs(english.strings) do
    english_key_count = english_key_count + 1
end
assert(english_key_count >= 25, "English locale has too few core strings")

for _, code in ipairs(codes) do
    local locale = require("./locales/" .. code)
    assert(locale.code == code, "locale code mismatch: " .. code)
    local count = 0
    for key in pairs(english.strings) do
        local value = locale.strings[key]
        assert(type(value) == "string" and value ~= "",
            code .. " is missing translation key " .. key)
        count = count + 1
    end
    for key in pairs(locale.strings) do
        assert(english.strings[key] ~= nil,
            code .. " contains unknown translation key " .. key)
    end
    assert(count == english_key_count, code .. " translation key count differs")

    local translator = localization.new(code)
    assert(translator.code == code, "translator selected wrong code for " .. code)
    local rendered = translator:text("kill_summary", {
        team_prefix = "",
        killer = "Tester",
        boss = "Boss",
        seconds = 10,
        dps = "1,000",
        damage = "10,000",
        players = 2,
    })
    assert(not string.find(rendered, "{", 1, true),
        code .. " left an unresolved placeholder")
end

assert(localization.new("schinese").code == "zh-CN")
assert(localization.new("tchinese").code == "zh-TW")
assert(localization.new("koreana").code == "ko")
assert(localization.new("latam").code == "es-419")
assert(localization.new("auto", function() return "zh-Hant-TW" end).code == "zh-TW")
assert(localization.new("auto", function() return "pt_BR" end).code == "pt-BR")
assert(localization.new("unsupported").code == "en")

print("PalSkillDPSAnalyzer localization tests passed for 17 languages")
