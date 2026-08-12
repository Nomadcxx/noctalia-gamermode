--!nonstrict
--
-- Bar widget: the word アニムー painted by a native animated gradient. There is no
-- backing rail, pill or box -- the moving light inside the glyphs is the whole
-- visual signal, which is the point the demo is making about ui.label gradients.

local PANEL_ID = "nomadcxx/animoo-noctalia:main"

-- The dim base ink. Alpha 0x10 keeps the word barely visible between passes so the
-- travelling crest reads as light moving through the glyphs rather than as text
-- changing colour. It is decorative: the tooltip and click target carry the identity.
local BASE = "#55edf510"
local CREST = "#f4ffff"

local M = {}

function M.buildTree()
    return ui.label({
        key = "animoo-wordmark",
        text = "アニムー",
        fontFamily = "Noto Sans Mono CJK JP",
        fontSize = 15,
        fontWeight = "bold",
        color = BASE,

        colors = { BASE, CREST, BASE },
        stops = { 0.40, 0.50, 0.60 },
        direction = "horizontal",
        motion = "loop",
        duration = 1800,
        -- The trip starts and ends outside the word, so the loop reset happens
        -- while the crest is off-glyph and is therefore invisible.
        offsetFrom = -0.60,
        offsetTo = 0.60,
        glowRadius = 3,
    })
end

-- English, so the widget stays identifiable even if the Japanese face falls back.
function M.tooltip()
    return "Animoo - native gradient text demo"
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

barWidget.setTooltip(M.tooltip())
barWidget.render(M.buildTree())

return M
