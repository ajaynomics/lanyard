# Flaky tests

Tests skipped because they fail now and then in CI for a reason not yet
found. Each is a quarantine, not a fix: find the cause, fix it, remove the
`skip` and its line here.

Class 1, system tests that acted before the page was settled, was fixed at
its cause in #596: after every action a test waits for the form's answer and
the page it draws, the phone's browser reduces motion as the shared one does,
and a wait that runs out fails saying what it waited for.

| Test | Symptom | Suspected cause | Next step |
|---|---|---|---|
| `agent/test/cdp.test.mjs`, "it holds its port while Chromium restarts, and serves the new one" (class: Chromium restart, #575) | After `Browser.close`, the replacement Chromium lists its page, but visit.mjs's `Target.createTarget` gets no reply within 5 s: "no tab for it: Target.createTarget took too long". Not reproduced locally. | Not found. A browser that dies mid-call closes visit.mjs's socket, and visit.mjs now fails at once saying so, so "took too long" means the new browser hung. | The test now waits for the launcher's second start and, on failure, prints cdp.mjs's and Chromium's output. Remove the skip, and read that output at the next failure. |
| `test/system/workspaces_overview_test.rb`, "from the agents list, every workspace's block; a stuck card opens in its own workspace" (class: never-settles, d7a62cb0) | CI run 10357: before clicking Overview, "The page is not settled: html[aria-busy]" (workspaces_overview_test.rb:33). Not reproduced locally. | Not found. Chrome's profile already moved to memory (#646), which fixed the forms that stayed busy; this is the page itself, after #646. | Read the failed test's log slice that #637 saves with its screenshots, for the request that held the page busy, then fix the cause and remove the skip. |
| `test/system/attaching_files_test.rb`, "the paperclip takes a .docx: a chip before sending, the path in what the agent reads, and a chip that downloads it after" (class: never-settles) | CI run 10681 (#698): "The page is not settled: form[aria-busy]" (application_system_test_case.rb:156), after attaching the .docx. Not reproduced locally. | Not found. The composer form stays busy past the 2 s wait after the upload; the server stall #661 fixed is the same symptom, so this may be a slow direct upload, not the page. | Read the failed test's log slice (#637) for the request that held the form busy, then fix the cause and remove the skip. |
| `test/system/conversation_test.rb`, "a pasted picture too large to send is made smaller first, and one the browser can't read is refused at once" (class: never-settles) | Runs 10571 (#681) and 10611 (#672): "The page is not settled: form[aria-busy]" (`Capybara::ExpectationNotMet`) on two unrelated PRs; main's runs pass. Not reproduced locally. | Not found. The composer form stays busy past the 2 s wait after sending a large picture: perhaps the picture's upload or the turbo-stream reply is slow on a loaded runner. | Read the failed test's log slice (#637) for the request that held the form busy, then fix the cause and remove the skip. |
