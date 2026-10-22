-- ElvUI skin for Rally. Loaded after Rally.lua; does nothing without ElvUI.
if not ElvUI then return end

local E = unpack(ElvUI)
local S = E and E:GetModule("Skins", true)
if not S then return end

Rally = Rally or {}

-- kind is one of "window", "cell", "castbutton", "list" (see Skin() calls in Rally.lua)
function Rally.Skin(kind, a, b, c)
	if kind == "window" then -- a = frame, b = close button, c = auto-assign button
		a:SetTemplate("Transparent")
		S:HandleCloseButton(b)
		S:HandleButton(c)
	elseif kind == "cell" then -- a = grid cell button
		a:SetTemplate("Default")
		a:StyleButton()
	elseif kind == "castbutton" then -- a = secure cast button
		S:HandleButton(a)
	elseif kind == "list" then -- a = missing-buffs list frame
		a:SetTemplate("Transparent")
	end
end
