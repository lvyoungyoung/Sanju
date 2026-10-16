// Tombstone: redeploy to disable the previously published matching endpoint.
Deno.serve(req => Response.json({ error: "Custom study themes have been retired", code: "feature_retired" },
  { status: req.method === "POST" ? 410 : 405 }))
