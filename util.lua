--[[pod_format="raw",created="2025-12-14 15:27:05",modified="2025-12-14 16:56:50",revision=75]]
function internet()
	return (fetch("https://raw.githubusercontent.com/Astralsparv/Distribution_Manager.p64/refs/heads/main/connection_test.txt"):sub(1,7)=="Working")
end

function downloadDistribution(source,label)
	if (source:prot()) then
		notify("Cannot download distributions from the internet. :C")
--		if (source:sub(1,19)=="https://github.com/") then
--			source=source:sub(20,-1)
--			source="https://raw.githubusercontent.com/"..source.."/refs/heads/main/"
--		end
--		
--		if (source:sub(-1)!="/") source..="/"
--		local list=fetch(source.."fs.pod")
--		
--		mkdir("/distributions/"..label)
--		cd("/distributions/"..label)
--		for k,v in ipairs(list) do
--			printh(k)
--			printh(v)
--			printh("")
--			mkdir(v)
--		end
	else
		cp(source,"/distributions/"..label)
	end
end