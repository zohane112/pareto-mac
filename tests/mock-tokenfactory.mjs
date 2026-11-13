// A stand-in for Nebius Token Factory, for testing the extension's Nemotron paths without a key
// or any spending. It speaks the same OpenAI-style API on localhost:
//   GET  /v1/models            the three Nemotron model ids
//   POST /v1/chat/completions  answers like each model would, by matching words:
//     Lightning, finding lines → JSON with the line that shares the most words with the question
//     Lightning, a sentence    → JSON with the sentence that shares the most words
//     Lightning, compare mode  → JSON with one line id
//     Lightning, Mac routing   → JSON with, for each question, the option sharing most words
//                                with the request (the Mac app's "what do you mean" questions)
//     Super                    → a one-line answer that quotes the best line
//     Ultra                    → a streamed reply: reasoning in pieces, then ANSWER and LINES
//   GET  /page.html            a small test article
//
// Questions containing "MOCK402" get HTTP 402 (out of credit).
//
//   import { startMock } from "./mock-tokenfactory.mjs";
//   const mock = await startMock();   // mock.url, mock.requests, mock.close()
//
// Or on its own, for the Mac app's self-test: node tests/mock-tokenfactory.mjs [--port 8765]
// The key it accepts is "mock-key".

import { createServer } from "node:http";

const MODELS = ["nvidia/Nemotron-3_5-Lightning", "nvidia/nemotron-3-super-120b-a12b", "nvidia/Nemotron-3-Ultra-550b-a55b"];
const STOP = new Set("the a an of to in is it and or for on with what how does do did when was were are this that which who why can its by from at be as".split(" "));
const wordsOf = (s) => new Set(String(s).toLowerCase().match(/[a-z0-9]+/g)?.filter((w) => w.length > 2 && !STOP.has(w)) ?? []);
const overlap = (a, b) => [...wordsOf(a)].filter((w) => wordsOf(b).has(w)).length;

// "c12| [Section] text" or "s3| text" lines inside a prompt.
function linesIn(text, prefix) {
  return [...text.matchAll(new RegExp(`^(${prefix}\\d+)\\| (.*)$`, "gm"))].map((m) => ({ id: m[1], text: m[2] }));
}
function ranked(lines, question) {
  return lines.map((l) => ({ ...l, score: overlap(question, l.text) })).filter((l) => l.score > 0).sort((a, b) => b.score - a.score);
}

export const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>The Tidewater Ferry</title></head><body>
<main><article>
<h1>The Tidewater Ferry</h1>
<p>The Tidewater Ferry crosses the inlet between Port Avery and Gull Island. It has run since 1962 and carries about 900 passengers a day in summer.</p>
<h2>Schedule</h2>
<p>Boats leave Port Avery every forty minutes from 6:20 in the morning until 10:40 at night. On Sundays the first boat leaves at 8:00.</p>
<p>In winter, from November to March, the late boats are cancelled and the last crossing leaves Gull Island at 7:15 in the evening.</p>
<h2>Fares</h2>
<p>A single adult ticket costs 6 dollars and a return costs 10. Children under twelve ride free with an adult, and bicycles cost 2 dollars each way.</p>
<p>Cars are carried only on the morning and evening boats, for 28 dollars including the driver. Booking a car space a day ahead is recommended in July and August.</p>
<h2>History</h2>
<p>The first ferry was a converted fishing boat named Margaret. The current boat, the Heron, was built in 1998 in a shipyard on the mainland and seats 240 people.</p>
<p>In 2021 the Heron was refitted with hybrid engines, which cut its fuel use by about a third.</p>
<h2>Accessibility</h2>
<p>Both terminals have step-free ramps, and the Heron has a lift between its two decks. Assistance dogs are welcome on every crossing.</p>
</article></main></body></html>`;

export async function startMock({ thinkSteps = 6, stepMs = 250, port = 0 } = {}) {
  const requests = [];
  const server = createServer(async (req, res) => {
    const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
    if (req.method === "OPTIONS") return res.writeHead(204, cors).end();
    if (req.url === "/page.html") return res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" }).end(PAGE);
    const auth = req.headers.authorization;
    if (req.url === "/v1/models") {
      requests.push({ kind: "models", auth });
      if (auth !== "Bearer mock-key") return res.writeHead(401, cors).end("bad key");
      return res.writeHead(200, { ...cors, "Content-Type": "application/json" }).end(JSON.stringify({ data: MODELS.map((id) => ({ id })) }));
    }
    if (req.url !== "/v1/chat/completions" || req.method !== "POST") return res.writeHead(404, cors).end();

    let raw = "";
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    const prompt = body.messages.map((m) => m.content).join("\n");
    const question = prompt.match(/Question: (.*)/)?.[1] ?? "";
    const kind = body.model.includes("Ultra") ? "deep"
      : body.model.includes("super") ? "answer"
      : /^s\d+\| /m.test(prompt) ? "sentence"
      : /"id": "<id/.test(prompt) ? "compare"
      : /Answer each question by picking one option id/.test(prompt) ? "route"
      : "find";
    requests.push({ kind, model: body.model, auth, thinking: body.chat_template_kwargs?.enable_thinking, stream: !!body.stream, question });
    if (auth !== "Bearer mock-key") return res.writeHead(401, cors).end("bad key");
    if (question.includes("MOCK402")) return res.writeHead(402, cors).end('{"error": "insufficient credit"}');

    const json = (content) => res.writeHead(200, { ...cors, "Content-Type": "application/json" }).end(JSON.stringify({
      model: body.model, choices: [{ message: { role: "assistant", content }, finish_reason: "stop" }], usage: { prompt_tokens: Math.round(prompt.length / 4), completion_tokens: 30 },
    }));
    const lines = linesIn(prompt, "c");
    const best = ranked(lines, question);

    if (kind === "find") {
      return setTimeout(() => json(JSON.stringify({ answered: best.length > 0, sure: best.length ? 90 : 10, lines: best.slice(0, 3).map((l) => l.id) })), 120);
    }
    if (kind === "compare") return json(JSON.stringify({ id: best[0]?.id ?? "c1", answered: best.length > 0 }));
    if (kind === "route") {
      const request = prompt.match(/Request: "(.*)"/)?.[1] ?? "";
      const picks = {};
      for (const block of prompt.split(/\nQuestion "/).slice(1)) {
        const name = block.slice(0, block.indexOf('"'));
        const options = [...block.matchAll(/^- ([\w.-]+)(?:: (.*))?$/gm)].map((m) => ({ id: m[1], text: m[2] ?? "" }));
        const scored = options.map((o) => ({ ...o, score: overlap(request, o.text) })).sort((a, b) => b.score - a.score);
        const pick = scored[0]?.score > 0 ? scored[0].id : (options.find((o) => o.id === "none") ?? options[0])?.id;
        picks[name] = { pick, sure: scored[0]?.score > 0 ? 85 : 40 };
      }
      return json(JSON.stringify(picks));
    }
    if (kind === "sentence") {
      const s = ranked(linesIn(prompt, "s"), question)[0]?.id ?? "s1";
      return json(JSON.stringify({ sentence: s }));
    }
    if (kind === "answer") {
      const excerpt = prompt.match(/^\[1\][^\n]*/m)?.[0]?.replace(/^\[1\](\s\([^)]*\))?\s*/, "") ?? "";
      return setTimeout(() => json(`From the page: ${excerpt.split(". ")[0]}.`), 200);
    }

    // Ultra: reasoning first, in pieces, then the answer, streamed as server-sent events.
    res.writeHead(200, { ...cors, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    const send = (obj) => res.write(`data: ${typeof obj === "string" ? obj : JSON.stringify(obj)}\n\n`);
    const delta = (d, finish = null) => send({ model: body.model, choices: [{ index: 0, delta: d, finish_reason: finish }] });
    delta({ role: "assistant" });
    for (let i = 0; i < thinkSteps; i++) {
      await new Promise((r) => setTimeout(r, stepMs));
      delta({ reasoning_content: `Step ${i + 1}: weighing which parts of the page answer "${question}". `.repeat(4) });
    }
    const used = best.slice(0, 2);
    const answer = used.length ? `Mock Ultra answer: ${used.map((l) => l.text.replace(/^\[[^\]]*\]\s*/, "").split(". ")[0]).join("; ")}.` : "This page doesn't say. Generally, mock.";
    delta({ content: `ANSWER: ${answer}\n` });
    await new Promise((r) => setTimeout(r, stepMs));
    delta({ content: `LINES: ${used.length ? used.map((l) => l.id).join(", ") : "none"}` }, "stop");
    send({ model: body.model, choices: [], usage: { prompt_tokens: Math.round(prompt.length / 4), completion_tokens: 400 } });
    send("[DONE]");
    res.end();
  });
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  const { port: bound } = server.address();
  return { url: `http://127.0.0.1:${bound}`, requests, close: () => new Promise((r) => server.close(r)) };
}

// Run on its own: node tests/mock-tokenfactory.mjs [--port 8765]
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[process.argv.indexOf("--port") + 1]) || 8765;
  const mock = await startMock({ port });
  console.log(`Stand-in Token Factory at ${mock.url}/v1 (key: mock-key). Ctrl+C to stop.`);
}
