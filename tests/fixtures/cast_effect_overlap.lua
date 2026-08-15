return {
    overlap = {
        events = {
            { kind = "cast_begin", at = 0.000, attacker_id = "pal:1:7", cast_id = "bubble:1", skill_code = "BubbleShower", action_instance_id = "action:10:1", waza_token_id = "waza:10:1" },
            { kind = "effect", at = 0.010, attacker_id = "pal:1:7", effect_id = "effect:bubble:20:1", cast_id = "bubble:1" },
            -- BubbleShower has ended. Its effect identity remains valid.
            { kind = "cast_begin", at = 1.050, attacker_id = "pal:1:7", cast_id = "apocalypse:1", skill_code = "Apocalypse", action_instance_id = "action:11:1", waza_token_id = "waza:11:1" },
            { kind = "effect", at = 1.060, attacker_id = "pal:1:7", effect_id = "effect:apocalypse:21:1", cast_id = "apocalypse:1" },
            { kind = "damage_info", at = 1.061, attacker_id = "pal:1:7", damage_info_id = "damage-info:apocalypse:30:1", effect_id = "effect:apocalypse:21:1" },
            { kind = "hit", seq = 1, at = 1.100, attacker_id = "pal:1:7", defender_id = "boss:1:2", effect_id = "effect:bubble:20:1", bp = 160, element = 8, damage = 31 },
            { kind = "hit", seq = 2, at = 1.110, attacker_id = "pal:1:7", defender_id = "boss:1:2", damage_info_id = "damage-info:apocalypse:30:1", bp = 400, element = 8, damage = 101 },
            { kind = "cast_begin", at = 1.120, attacker_id = "pal:1:7", cast_id = "gravity:1", skill_code = "GravityShot", action_instance_id = "action:12:1", waza_token_id = "waza:12:1" },
            { kind = "hit", seq = 3, at = 1.130, attacker_id = "pal:1:7", defender_id = "boss:1:2", effect_id = "effect:bubble:20:1", bp = 160, element = 8, damage = 29 },
            { kind = "hit", seq = 4, at = 1.140, attacker_id = "pal:1:7", defender_id = "boss:1:2", damage_info_id = "damage-info:apocalypse:30:1", bp = 400, element = 8, damage = 103 },
            { kind = "hit", seq = 5, at = 1.150, attacker_id = "pal:1:7", defender_id = "boss:1:2", direct_waza_token_id = "waza:12:1", bp = 40, element = 8, damage = 40 },
        },
        expected_hits = {
            { cast_id = "bubble:1", skill_code = "BubbleShower", evidence_kind = "effect_cast_link" },
            { cast_id = "apocalypse:1", skill_code = "Apocalypse", evidence_kind = "damage_info_cast_link" },
            { cast_id = "bubble:1", skill_code = "BubbleShower", evidence_kind = "effect_cast_link" },
            { cast_id = "apocalypse:1", skill_code = "Apocalypse", evidence_kind = "damage_info_cast_link" },
            { cast_id = "gravity:1", skill_code = "GravityShot", evidence_kind = "direct_waza_token" },
        },
        expected_skills = {
            BubbleShower = { damage = 60, hits = 2 },
            Apocalypse = { damage = 204, hits = 2 },
            GravityShot = { damage = 40, hits = 1 },
        },
        expected_total = { damage = 304, hits = 5, unresolved_damage = 0, unresolved_hits = 0 },
    },

    -- Real regression shape: IceAge and Apocalypse keep producing delayed
    -- hits after newer basic/active skills begin. Only their exact effect or
    -- DamageInfo identity may decide the bucket; event order and signatures
    -- are deliberately misleading.
    sustained_exact_overlap = {
        events = {
            { kind = "cast_begin", at = 0.000, attacker_id = "pal:rain:7", cast_id = "ice-age:1", skill_code = "IceAge", action_instance_id = "action:ice:1", waza_token_id = "waza:ice:1" },
            { kind = "effect", at = 0.010, attacker_id = "pal:rain:7", effect_id = "effect:ice:1", cast_id = "ice-age:1" },
            { kind = "damage_info", at = 0.011, attacker_id = "pal:rain:7", damage_info_id = "damage-info:ice:1", effect_id = "effect:ice:1" },
            { kind = "cast_begin", at = 1.000, attacker_id = "pal:rain:7", cast_id = "apocalypse:1", skill_code = "Apocalypse", action_instance_id = "action:apocalypse:1", waza_token_id = "waza:apocalypse:1" },
            { kind = "effect", at = 1.010, attacker_id = "pal:rain:7", effect_id = "effect:apocalypse:1", cast_id = "apocalypse:1" },
            { kind = "damage_info", at = 1.011, attacker_id = "pal:rain:7", damage_info_id = "damage-info:apocalypse:1", effect_id = "effect:apocalypse:1" },

            -- IceAge lands after Apocalypse has become the current action.
            { kind = "hit", seq = 1, at = 1.020, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", damage_info_id = "damage-info:ice:1", current_action = "Apocalypse", recent_action = "IceAge", bp = 160, element = 6, damage = 80 },
            { kind = "hit", seq = 2, at = 1.030, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", damage_info_id = "damage-info:apocalypse:1", bp = 400, element = 8, damage = 101 },

            { kind = "cast_begin", at = 1.040, attacker_id = "pal:rain:7", cast_id = "gravity:1", skill_code = "GravityShot", action_instance_id = "action:gravity:1", waza_token_id = "waza:gravity:1" },
            { kind = "hit", seq = 3, at = 1.050, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", direct_waza_token_id = "waza:gravity:1", bp = 40, element = 8, damage = 40 },
            -- Apocalypse tail lands after GravityShot starts.
            { kind = "hit", seq = 4, at = 1.060, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", damage_info_id = "damage-info:apocalypse:1", current_action = "GravityShot", recent_action = "Apocalypse", bp = 400, element = 8, damage = 103 },

            { kind = "cast_begin", at = 1.070, attacker_id = "pal:rain:7", cast_id = "sand:1", skill_code = "SandTwister", action_instance_id = "action:sand:1", waza_token_id = "waza:sand:1" },
            { kind = "effect", at = 1.071, attacker_id = "pal:rain:7", effect_id = "effect:sand:1", cast_id = "sand:1" },
            { kind = "hit", seq = 5, at = 1.080, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", effect_id = "effect:sand:1", bp = 80, element = 3, damage = 55 },
            -- Both older sustained effects continue after SandTwister starts.
            { kind = "hit", seq = 6, at = 1.090, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", effect_id = "effect:ice:1", current_action = "SandTwister", bp = 160, element = 6, damage = 82 },
            { kind = "hit", seq = 7, at = 1.100, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", damage_info_id = "damage-info:apocalypse:1", current_action = "SandTwister", bp = 400, element = 8, damage = 107 },

            -- Same signature/current-action hints without an exact token must
            -- remain unresolved instead of entering Apocalypse.
            { kind = "hit", seq = 8, at = 1.110, attacker_id = "pal:rain:7", defender_id = "boss:rain:1", current_action = "Apocalypse", recent_action = "SandTwister", bp = 400, element = 8, damage = 17 },
        },
        expected_hits = {
            { cast_id = "ice-age:1", skill_code = "IceAge", evidence_kind = "damage_info_cast_link" },
            { cast_id = "apocalypse:1", skill_code = "Apocalypse", evidence_kind = "damage_info_cast_link" },
            { cast_id = "gravity:1", skill_code = "GravityShot", evidence_kind = "direct_waza_token" },
            { cast_id = "apocalypse:1", skill_code = "Apocalypse", evidence_kind = "damage_info_cast_link" },
            { cast_id = "sand:1", skill_code = "SandTwister", evidence_kind = "effect_cast_link" },
            { cast_id = "ice-age:1", skill_code = "IceAge", evidence_kind = "effect_cast_link" },
            { cast_id = "apocalypse:1", skill_code = "Apocalypse", evidence_kind = "damage_info_cast_link" },
            { evidence_kind = "unresolved" },
        },
        expected_skills = {
            IceAge = { damage = 162, hits = 2 },
            Apocalypse = { damage = 311, hits = 3 },
            GravityShot = { damage = 40, hits = 1 },
            SandTwister = { damage = 55, hits = 1 },
        },
        expected_total = { damage = 585, hits = 8, unresolved_damage = 17, unresolved_hits = 1 },
    },

    same_signature_exact = {
        events = {
            { kind = "cast_begin", attacker_id = "pal:2:4", cast_id = "same-a:1", skill_code = "SameSignatureA" },
            { kind = "effect", attacker_id = "pal:2:4", effect_id = "effect:same-a:1", cast_id = "same-a:1" },
            { kind = "cast_begin", attacker_id = "pal:2:4", cast_id = "same-b:1", skill_code = "SameSignatureB" },
            { kind = "effect", attacker_id = "pal:2:4", effect_id = "effect:same-b:1", cast_id = "same-b:1" },
            { kind = "hit", seq = 1, attacker_id = "pal:2:4", defender_id = "boss:2:3", effect_id = "effect:same-a:1", bp = 160, element = 8, damage = 47 },
            { kind = "hit", seq = 2, attacker_id = "pal:2:4", defender_id = "boss:2:3", effect_id = "effect:same-b:1", bp = 160, element = 8, damage = 53 },
        },
        expected_hits = {
            { cast_id = "same-a:1", skill_code = "SameSignatureA", evidence_kind = "effect_cast_link" },
            { cast_id = "same-b:1", skill_code = "SameSignatureB", evidence_kind = "effect_cast_link" },
        },
        expected_skills = {
            SameSignatureA = { damage = 47, hits = 1 },
            SameSignatureB = { damage = 53, hits = 1 },
        },
        expected_total = { damage = 100, hits = 2, unresolved_damage = 0, unresolved_hits = 0 },
    },

    same_signature_weak = {
        events = {
            { kind = "cast_begin", attacker_id = "pal:3:2", cast_id = "weak-a:1", skill_code = "WeakA" },
            { kind = "cast_begin", attacker_id = "pal:3:2", cast_id = "weak-b:1", skill_code = "WeakB" },
            { kind = "hit", seq = 1, attacker_id = "pal:3:2", defender_id = "boss:3:9", current_action = "WeakA", recent_action = "WeakB", bp = 160, element = 8, damage = 47 },
            { kind = "hit", seq = 2, attacker_id = "pal:3:2", defender_id = "boss:3:9", current_action = "WeakB", recent_action = "WeakA", bp = 160, element = 8, damage = 53 },
        },
        expected_hits = {
            { evidence_kind = "unresolved" },
            { evidence_kind = "unresolved" },
        },
        expected_skills = {},
        expected_total = { damage = 100, hits = 2, unresolved_damage = 100, unresolved_hits = 2 },
    },

    wrapper_copy_propagated = {
        events = {
            { kind = "cast_begin", attacker_id = "pal:4:8", cast_id = "wrapper:1", skill_code = "WrappedRain" },
            { kind = "effect", attacker_id = "pal:4:8", effect_id = "effect:wrapper:1", cast_id = "wrapper:1" },
            { kind = "damage_info", attacker_id = "pal:4:8", damage_info_id = "damage-info:original:1", effect_id = "effect:wrapper:1" },
            { kind = "damage_info", attacker_id = "pal:4:8", damage_info_id = "damage-info:copy:1", parent_damage_info_id = "damage-info:original:1" },
            { kind = "hit", seq = 1, attacker_id = "pal:4:8", defender_id = "boss:4:5", damage_info_id = "damage-info:copy:1", bp = 200, element = 4, damage = 71 },
        },
        expected_hits = {
            { cast_id = "wrapper:1", skill_code = "WrappedRain", evidence_kind = "damage_info_cast_link" },
        },
        expected_skills = { WrappedRain = { damage = 71, hits = 1 } },
        expected_total = { damage = 71, hits = 1, unresolved_damage = 0, unresolved_hits = 0 },
    },

    wrapper_copy_unpropagated = {
        events = {
            { kind = "cast_begin", attacker_id = "pal:5:6", cast_id = "wrapper-miss:1", skill_code = "WrappedRain" },
            { kind = "effect", attacker_id = "pal:5:6", effect_id = "effect:wrapper-miss:1", cast_id = "wrapper-miss:1" },
            { kind = "damage_info", attacker_id = "pal:5:6", damage_info_id = "damage-info:original:2", effect_id = "effect:wrapper-miss:1" },
            -- The copy has no parent token. Registering it must fail closed.
            { kind = "damage_info_unlinked", attacker_id = "pal:5:6", damage_info_id = "damage-info:copy:2" },
            { kind = "hit", seq = 1, attacker_id = "pal:5:6", defender_id = "boss:5:1", damage_info_id = "damage-info:copy:2", current_action = "WrappedRain", bp = 200, element = 4, damage = 71 },
        },
        expected_hits = { { evidence_kind = "unresolved" } },
        expected_skills = {},
        expected_total = { damage = 71, hits = 1, unresolved_damage = 71, unresolved_hits = 1 },
    },
}
