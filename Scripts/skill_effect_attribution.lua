-- Asset-backed skill attribution rules discovered from Palworld's cooked
-- Blueprint data. Only add a rule when the damaging effect itself declares
-- the Waza or has an equally direct parent/owner chain.

local M = {}

local rules = {
    {
        code = "DiamondFall",
        waza = "EPalWazaID::DiamondFall",
        phases = {
            {
                token = "SkillEffect_DiamondFall_Fall",
                name = "fall_impact",
                power_rate = 0.05,
            },
            {
                token = "SkillEffect_DiamondFall_Explode",
                name = "ground_explosion",
                power_rate = 0.05,
            },
        },
    },
}

function M.resolve(object_info)
    object_info = object_info or {}
    local evidence = table.concat({
        tostring(object_info.full_name or ""),
        tostring(object_info.short_name or ""),
        tostring(object_info.class_name or ""),
    }, "|")

    for _, rule in ipairs(rules) do
        for _, phase in ipairs(rule.phases) do
            if string.find(evidence, phase.token, 1, true) ~= nil then
                return {
                    code = rule.code,
                    waza = rule.waza,
                    phase = phase.name,
                    power_rate = phase.power_rate,
                    matched_token = phase.token,
                }
            end
        end
    end
    return nil
end

return M
