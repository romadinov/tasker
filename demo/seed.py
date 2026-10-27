import json, subprocess, os, sys
db = sys.argv[1]
mcp = sys.argv[2]
calls = []
def tool(name, **a): calls.append((name, a))
for p in ["Home : Kitchen renovation", "Home : Garden", "Work : Website relaunch", "Work : Quarterly planning", "Personal : Trip to Lisbon", "Personal : Learn Spanish"]:
    tool("create_project", path=p)
T = lambda title, **k: tool("create_task", title=title, **k)
T("Get quotes from three contractors", project="Home : Kitchen renovation", tags=["Calls"], due="+2d", flagged=True)
T("Pick cabinet colours", project="Home : Kitchen renovation", tags=["Home"], planned="tomorrow")
T("Order the new tap", project="Home : Kitchen renovation", tags=["Errands"], due="+5d")
T("Measure the window wall", project="Home : Kitchen renovation", tags=["Home"])
T("Plant spring bulbs", project="Home : Garden", tags=["Home"], due="+9d")
T("Buy compost and mulch", project="Home : Garden", tags=["Errands"], planned="+3d")
T("Fix the hose reel", project="Home : Garden", tags=["Home"])
T("Write homepage copy", project="Work : Website relaunch", tags=["Focus"], due="tomorrow", flagged=True, estimate_minutes=90)
T("Review new design mock-ups", project="Work : Website relaunch", tags=["Focus"], due="today")
T("Ask Maria about the analytics setup", project="Work : Website relaunch", tags=["Waiting"])
T("Set up redirects for old pages", project="Work : Website relaunch", tags=["Computer"], planned="+4d")
T("Draft goals for next quarter", project="Work : Quarterly planning", tags=["Focus"], due="+6d")
T("Collect team feedback", project="Work : Quarterly planning", tags=["Calls"], planned="+2d")
T("Book the budget review meeting", project="Work : Quarterly planning", tags=["Calls"], due="+3d", flagged=True)
T("Book flights", project="Personal : Trip to Lisbon", tags=["Computer"], due="+4d", flagged=True)
T("Find a hotel in Alfama", project="Personal : Trip to Lisbon", tags=["Computer"])
T("Make a list of restaurants", project="Personal : Trip to Lisbon", tags=["Home"], planned="+6d")
T("Practise for twenty minutes", project="Personal : Learn Spanish", tags=["Focus"], due="today")
T("Watch a film without subtitles", project="Personal : Learn Spanish", tags=["Home"], planned="+5d")
T("Call the dentist", tags=["Calls"])
T("Pick up dry cleaning", tags=["Errands"], due="tomorrow")
T("Renew passport")
T("Idea: weekend bike route along the coast")
lines = [json.dumps({"jsonrpc":"2.0","id":0,"method":"initialize","params":{}})]
for i,(n,a) in enumerate(calls, 1):
    lines.append(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":n,"arguments":a}}))
r = subprocess.run([mcp], input="\n".join(lines)+"\n", capture_output=True, text=True, env={**os.environ, "TASKER_DB": db})
errs = [l for l in r.stdout.splitlines() if '"isError":true' in l or '"error"' in l]
print(len(calls), "calls;", len(errs), "errors"); print("\n".join(errs[:3])); print(r.stderr[-500:])
