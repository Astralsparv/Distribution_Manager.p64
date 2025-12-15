--[[pod_format="raw",created="2025-12-14 15:00:34",modified="2025-12-14 15:02:21",revision=6]]
argv = env().argv
if (argv[1]) then
	store("/distributions/bootinto.txt",argv[1])
	send_message(2,{event="reboot"})
else
	print("bootinto <distribution>")
end