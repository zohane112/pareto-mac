# Tests: Pareto for Mac

## Nemotron, 1.4.0 (2026-10-27): passed against a stand-in Nebius

1.4.0 adds NVIDIA Nemotron on Nebius Token Factory. There was no Nebius key yet, so `--nemotron` ran against the stand-in server (`node tests/mock-tokenfactory.mjs`), which answers the way each model would by matching words. These runs prove the wiring, not Nemotron's accuracy or speed.

| Run | Result |
| --- | --- |
| `--nemotron` with no Jev key (`CTRLF_NO_JEV=1`) | 14 of 14 |
| `--nemotron` with a made-up Jev key, which the real Jev refuses | all passed; every search and request says `Lightning · … · Jev key refused` |
| `--selftest` (no Jev calls) | all passed, as before |
| `--render` | the answer card with Super's answer, the think-harder card, and the settings step for the Nebius key all draw correctly |

What `--nemotron` covers:

- **The key check** lists Lightning ✓ Super ✓ Ultra ✓.
- **Finding:** on the test PDF, Lightning finds page 3 and the pet deposit sentence. With no Jev key it does the finding itself, and a question the PDF can't answer comes back not found.
- **Written answers:** Nemotron 3 Super writes one.
- **Think harder:** Ultra's reply streams, its progress goes from thinking to writing, and it names the passages it used.
- **The bar's own logic** on the test PDF: a search shows Lightning's page, the sentence and Super's answer. Then ⌘ ↵ hands the same PDF to Ultra, and the status line reads `nemotron 3 ultra · thinking · …` while it streams. The test switches the plan to AI for this and puts the saved plan back afterwards.
- **Routing:** "open safari", "when is the rent due?" and "search the web for weather in vancouver" go through Lightning in Jev's answer shape. Against the stand-in it only checks that the answers are read correctly. Against the real Nebius it checks they're right.

Run 2026-09-28 by Claude on the user's Mac (macOS 27, Apple silicon), with real Jev (`jev-latest`).

## Self-test (`--selftest --jev`): all passed

| Area | What was checked | Result |
| --- | --- | --- |
| Apps | apps found in the Applications folders | 146 |
| | "open safari", "calc", "launch the notes app", "ss" (initials) | Safari, Calculator, Notes, System Settings |
| Text | sentence splitting, merging tiny bits, splitting a 900-word block, keywords | ✓ |
| | a paragraph split by a link on a web page is joined back | ✓ |
| Files | Spotlight by name and contents; "pdf" finds only PDFs | ✓ |
| Sums | `12*4.5`, `(3+4)/2`, `15% of 80`, `(12*4.5)+15% of 80`, `2^10`, `-3 + 5` | 54, 3.5, 12, 66, 1024, 2 |
| | `1/0`, `2+`, `open notes`, `1.2.3+4`, `100` | not treated as sums |
| Web | "go to youtube.com" opens the site; "search the web for …" drops the command | ✓ |
| PDF | a 3-page test PDF: "how much do I pay to keep a dog?" | page 3, 92% sure, "The pet deposit is 300 dollars…" |
| | "what is the wifi password?" | not found (3%) |

### What Jev made of plain-English requests

With Google Chrome in front and Wikipedia's "Artificial intelligence" open:

| Request | Jev's reading | Time |
| --- | --- | --- |
| open safari | open app: Safari (100%) | 111 ms |
| launch the app I use for writing notes | open app: Notes (100%) | 89 ms |
| i want to do some maths | open app: Calculator | 213 ms |
| open whatsapp | open app: WhatsApp (100%) | 115 ms |
| put on some music on spotify | open app: Spotify (99%) | 100 ms |
| when did deep blue beat kasparov? | ask the front window | 123 ms |
| what does it say about the history of AI | ask the front window (99%) | 114 ms |
| summarize this | ask the front window (100%) | 122 ms |
| find the readme for the chrome extension | files: README.md | 183 ms |
| show me my screenshots | files: screenshots | 116 ms |
| search the web for weather in vancouver | web (100%) | 83 ms |
| go to youtube.com | web (100%) | 92 ms |

Also checked with `--route`:
- "my tax pdf from march" found 2026 Tax Form - Canada filled.pdf.
- "the screenshot I took last week" found a screenshot from 22 Sep. It knows today's date.

## The real app, driven by test links

Started with `CTRLF_TEST=1`. Pictures were saved by the app itself:
- The empty bar with example requests; after use, with recents.
- "calc": Calculator first, and only files named like it.
- "i want to do some maths": Jev picks Calculator, 99%, 148 ms.
- "show me my screenshots": screenshots, newest first.
- Typing "the app for doing maths" then Enter at once: it waited for Jev, then opened Calculator, which was added to recents.
- A PDF question: "how much is the pet deposit?" → 99% sure, page 3, 103 ms, with the exact sentence. "when is rent due" → page 2. **open at page** opened the PDF viewer at the right page.
- A sum, `(12*4.5)+15% of 80`, showed "= 66", and Enter copied it.
- The welcome/settings window, with and without a key.
- Without `CTRLF_TEST=1`, test links do nothing but open the bar. For example, `snapshot` wrote no file.

## The download

`dist/Ctrl+F-by-meaning-1.0.0.dmg` was mounted, the app copied out, and `--selftest` passed on both halves of the universal app: arm64, and x86_64 under Rosetta. `hdiutil verify` passed, and the signature is ad hoc.

## Not tested yet: needs a person at the Mac

- **Reading other apps' windows**, which needs the Accessibility permission. Neither this session's shell nor screen control could get it. The code reads Chrome/Electron (after asking them to share page text, with one retry), Safari, Mail, Notes and TextEdit (paragraph by paragraph), and PDFs from their files. It skips password fields and one-line boxes.
- **Hold-to-talk voice**, which needs the microphone and someone speaking.
- **The global shortcut from a real key press.**
- **Open at login.**
