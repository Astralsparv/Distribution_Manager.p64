
local p = fetch"/ram/system/processes.pod"

print("\014\fe pid  name                 cpu   pri   mem\|i")
--	print("\014 =============================")

for i=1,#p do

	print(string.format("\014 \f6%-4d \f7%-20s \f6%0.3f %s%0.3f \f6%dk",
		p[i].id, p[i].name, p[i].cpu, p[i].priority <= 0.2 and (p[i].priority < 0.001 and "\f1" or "\fg") or "\f6", p[i].priority, p[i].memory\1024))
	
end

print("\|i\0")
