package.path = "../Scripts/?.lua;" .. package.path

local localization = require("./localization")
local hud_strings = require("./hud_strings")
local skill_names = require("./skill_names")
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

    local hud_locale = hud_strings.strings[code]
    assert(type(hud_locale) == "table", code .. " is missing HUD translations")
    for key in pairs(hud_strings.strings.en) do
        assert(type(hud_locale[key]) == "string" and hud_locale[key] ~= "",
            code .. " is missing HUD translation key " .. key)
    end
    local hud_extra = hud_strings.extra_strings[code]
    assert(type(hud_extra) == "table", code .. " is missing damage-lab workspace translations")
    for key in pairs(hud_strings.extra_strings.en) do
        assert(type(hud_extra[key]) == "string" and hud_extra[key] ~= "",
            code .. " is missing damage-lab translation key " .. key)
    end
    assert((skill_names.coverage[code] or 0) >= 350,
        code .. " has unexpectedly low bundled skill-name coverage")
    assert(type(hud_strings.skill_category_names[code]) == "string"
        and hud_strings.skill_category_names[code] ~= "",
        code .. " is missing the basic-attack category name")
    assert(type(hud_strings.other_category_names[code]) == "string"
        and hud_strings.other_category_names[code] ~= "",
        code .. " is missing the unattributed-damage category name")
end

assert(localization.new("schinese").code == "zh-CN")
assert(localization.new("tchinese").code == "zh-TW")
assert(localization.new("koreana").code == "ko")
assert(localization.new("latam").code == "es-419")
assert(localization.new("auto", function() return "zh-Hant-TW" end).code == "zh-TW")
assert(localization.new("auto", function() return "pt_BR" end).code == "pt-BR")
assert(localization.new("unsupported").code == "en")
assert(#localization.language_options() == 18, "language selector must include auto plus 17 languages")
assert(localization.language_name("zh-TW") == "繁體中文")
assert(skill_names.skill_count >= 380, "bundled skill-name table is incomplete")
assert(skill_names.get("BeamSlicer", "zh-TW") == "切割龍息")
assert(skill_names.get("BeamSlicer", "en") == "Beam Slicer")
assert(skill_names.get("BeamSlicer", "ja") == "ビームスライサー")

print("PalSkillDPSAnalyzer localization tests passed for 17 languages")
