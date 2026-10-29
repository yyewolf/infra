// Entrypoint for jmap-mcp in this cluster. It replaces upstream's mod.ts and
// reuses upstream's tool code unmodified.
//
// The agent behind this server reads mail, and mail is written by strangers. So
// what the server can do has to be safe even when the agent is following
// instructions from an email. Two independent allow-lists enforce that:
//
// 1. Tool names. Only the tools in ALLOWED_TOOLS are registered; anything else
//    upstream registers (delete_emails today, whatever a later version adds) is
//    dropped. The submission tools (send_email, reply_to_email) are never even
//    imported.
//
// 2. JMAP methods on the wire. Every request to Stalwart goes through
//    guardedFetch, which only lets through reads and Email/set *updates* that
//    touch keywords or mailbox membership — no create, no destroy, no
//    EmailSubmission, no Sieve, no Mailbox/set, no blob upload or download.
//    This is the layer that holds if the first one has a bug, and it is why
//    the credential can be the account's full app password.
//
// Also refused: moving mail into the Trash or Junk mailbox (an indirect delete,
// since Stalwart purges Trash on its own), and the $deleted keyword (an IMAP
// client's EXPUNGE would remove anything carrying it).
//
// guardedFetch also does the two things the upstream client cannot: Stalwart
// only accepts the app password as HTTP Basic, while jmap-jam sends Bearer;
// and the session document advertises the public URL, which is rewritten to
// the in-cluster Service so calls never leave the cluster.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { connectJmap, type JmapConnection } from "@wyattjoh/jmap";
import { z } from "zod";

import deno from "../deno.json" with { type: "json" };
import { registerEmailTools } from "./tools/email.ts";

const ALLOWED_TOOLS = new Set([
  "search_emails",
  "get_mailboxes",
  "get_emails",
  "get_threads",
  "get_email_changes",
  "get_search_updates",
  "mark_emails",
  "move_emails",
  "patch_email_mailboxes",
]);

const READ_METHODS = new Set([
  "Core/echo",
  "Mailbox/get",
  "Mailbox/query",
  "Mailbox/changes",
  "Mailbox/queryChanges",
  "Email/get",
  "Email/query",
  "Email/changes",
  "Email/queryChanges",
  "Thread/get",
  "Thread/changes",
  "SearchSnippet/get",
]);

const BLOCKED_ROLES = new Set(["trash", "junk"]);

// create_folder may make a top-level folder, or a subfolder of a top-level
// folder that has no role — so at most two levels, and never inside Inbox,
// Trash, Junk, Drafts, Sent or the like. MAX_MAILBOXES caps the whole account,
// which is what bounds an email that talks the agent into making folders.
const MAX_MAILBOXES = 60;
const FOLDER_NAME = /^[\p{L}\p{N}][\p{L}\p{N} &'.,-]{0,39}$/u;
const BLOCKED_KEYWORDS = new Set(["$deleted"]);

const env = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing environment variable ${name}`);
  return value;
};

// http://stalwart.stalwart.svc.cluster.local:8080
const internalOrigin = new URL(env("JMAP_INTERNAL_URL")).origin;
// https://stalwart.yewolf.fr, what the session document advertises
const publicOrigin = new URL(env("JMAP_PUBLIC_URL")).origin;
const authorization = "Basic " +
  btoa(`${env("JMAP_USERNAME")}:${env("JMAP_PASSWORD")}`);

// Filled in at startup, before the server accepts a request.
const blockedMailboxIds = new Set<string>();
// Ids of top-level folders with no role: the only valid parents. Kept up to
// date as folders are created, like the total; a restart recounts both.
const parentIds = new Set<string>();
let mailboxCount = 0;

class Refused extends Error {}

const checkEmailSet = (args: Record<string, unknown>) => {
  // A back-reference ("#destroy": {resultOf: ...}) is resolved by the server
  // from an earlier call's result, so the checks below would never see what it
  // expands to. "#destroy" pointing at an Email/query is "delete everything
  // that search matched". Upstream's tools never send one.
  for (const key of Object.keys(args)) {
    if (key.startsWith("#")) {
      throw new Refused(`Email/set back-reference ${key} is not allowed`);
    }
  }
  for (const key of ["create", "destroy"]) {
    const v = args[key];
    if (v != null && Object.keys(v as object).length > 0) {
      throw new Refused(`Email/set ${key} is not allowed`);
    }
  }
  const update = (args.update ?? {}) as Record<string, Record<string, unknown>>;
  for (const patch of Object.values(update)) {
    for (const [path, value] of Object.entries(patch)) {
      const [field, member] = path.split("/", 2);
      if (field === "keywords") {
        const set = member ? (value ? [member] : []) : Object.keys(value ?? {});
        for (const k of set) {
          if (BLOCKED_KEYWORDS.has(k.toLowerCase())) {
            throw new Refused(`keyword ${k} is not allowed`);
          }
        }
      } else if (field === "mailboxIds") {
        const set = member ? (value ? [member] : []) : Object.keys(value ?? {});
        for (const id of set) {
          if (blockedMailboxIds.has(id)) {
            throw new Refused(`moving mail into Trash or Junk is not allowed`);
          }
        }
      } else {
        throw new Refused(`Email/set may not change ${field}`);
      }
    }
  }
};

// Mailbox/set may only create, at top level or under a role-less top-level
// folder, with a plain name, up to MAX_MAILBOXES in all. No update (that would
// allow renaming or re-parenting any folder, Inbox included), no destroy, no
// back-references.
const checkMailboxSet = (args: Record<string, unknown>) => {
  for (const key of Object.keys(args)) {
    if (!["accountId", "create"].includes(key)) {
      throw new Refused(`Mailbox/set ${key} is not allowed`);
    }
  }
  const create = Object.values(
    (args.create ?? {}) as Record<string, Record<string, unknown>>,
  );
  for (const mb of create) {
    for (const key of Object.keys(mb)) {
      if (!["name", "parentId", "isSubscribed"].includes(key)) {
        throw new Refused(`a new folder may not set ${key}`);
      }
    }
    const parent = mb.parentId ?? null;
    if (parent !== null && !parentIds.has(parent as string)) {
      throw new Refused(
        "folders may only be created at top level or inside a top-level " +
          "folder that is not a system folder",
      );
    }
    if (typeof mb.name !== "string" || !FOLDER_NAME.test(mb.name)) {
      throw new Refused(`folder name must be 1-40 plain characters`);
    }
  }
  if (mailboxCount + create.length > MAX_MAILBOXES) {
    throw new Refused(`the mailbox already has ${mailboxCount} folders`);
  }
};

const checkApiBody = (body: string) => {
  const req = JSON.parse(body) as { methodCalls?: unknown[] };
  for (const call of req.methodCalls ?? []) {
    const [method, args] = call as [string, Record<string, unknown>];
    if (READ_METHODS.has(method)) continue;
    if (method === "Email/set") {
      checkEmailSet(args);
      continue;
    }
    if (method === "Mailbox/set") {
      checkMailboxSet(args);
      continue;
    }
    throw new Refused(`JMAP method ${method} is not allowed`);
  }
};

const nativeFetch = globalThis.fetch;

const guardedFetch: typeof fetch = async (input, init) => {
  const original = new Request(input, init);
  const url = new URL(original.url);
  if (url.origin === publicOrigin) {
    url.protocol = new URL(internalOrigin).protocol;
    url.host = new URL(internalOrigin).host;
  }
  if (url.origin !== internalOrigin) {
    throw new Refused(`request to ${url.origin} is not allowed`);
  }

  let body: string | undefined;
  if (original.method === "GET" && url.pathname === "/jmap/session") {
    // the session document
  } else if (original.method === "POST" && url.pathname === "/jmap/") {
    body = await original.text();
    checkApiBody(body);
  } else {
    throw new Refused(`${original.method} ${url.pathname} is not allowed`);
  }

  const headers = new Headers(original.headers);
  headers.set("Authorization", authorization);
  return nativeFetch(url, {
    method: original.method,
    headers,
    redirect: "error",
    ...(body !== undefined && { body }),
  });
};

globalThis.fetch = guardedFetch;

// Registers upstream's email tools on `server`, minus anything not allowed.
const registerAllowedTools = (server: McpServer, connection: JmapConnection) => {
  const filtered = new Proxy(server, {
    get(target, prop, receiver) {
      if (prop === "tool" || prop === "registerTool") {
        return (name: string, ...rest: unknown[]) => {
          if (!ALLOWED_TOOLS.has(name)) {
            console.warn(`not registering tool ${name}`);
            return undefined;
          }
          // deno-lint-ignore no-explicit-any
          return (target as any)[prop](name, ...rest);
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  });
  registerEmailTools(filtered, connection);
  registerTriageTools(server, connection);
};

// Upstream can only set $seen and $flagged. The triage agent needs its own
// tags, from a fixed list, to mark what it has handled and how it classified
// it. They go through guardedFetch like everything else.
const TAGS = [
  "triaged",
  "important",
  "admin",
  "money",
  "useless",
  "unsubscribe",
] as const;

const textResult = (value: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value) }],
});

const TagEmailsSchema = z.object({
  ids: z.array(z.string()).min(1).max(100),
  add: z.array(z.enum(TAGS)).default([]),
  remove: z.array(z.enum(TAGS)).default([]),
});

const NotifyImportantSchema = z.object({
  emails: z.array(z.object({
    from: z.string(),
    subject: z.string(),
    category: z.enum(["admin", "money"]),
    why: z.string().describe("One sentence: what the user has to know or do."),
  })).min(1).max(20),
});

const CreateFolderSchema = z.object({
  name: z.string().regex(FOLDER_NAME).describe(
    "Short generic category, e.g. 'Bank', 'Subscriptions', 'Shipping'",
  ),
  parentId: z.string().optional().describe(
    "Id of a top-level, non-system folder to create it in. Omit for a top-level folder.",
  ),
});

const registerTriageTools = (server: McpServer, connection: JmapConnection) => {
  server.tool(
    "tag_emails",
    `Add or remove triage tags on emails. Tags: ${TAGS.join(", ")}.`,
    TagEmailsSchema.shape,
    async ({ ids, add, remove }: z.infer<typeof TagEmailsSchema>) => {
      const patch: Record<string, true | null> = {};
      for (const t of add) patch[`keywords/${t}`] = true;
      for (const t of remove) patch[`keywords/${t}`] = null;
      try {
        const [result] = await connection.client.api.Email.set({
          accountId: connection.accountId,
          update: Object.fromEntries(ids.map((id) => [id, patch])),
        });
        return textResult({
          updated: Object.keys(result.updated ?? {}),
          notUpdated: result.notUpdated ?? {},
        });
      } catch (error) {
        return {
          ...textResult(`Error tagging emails: ${(error as Error).message}`),
          isError: true,
        };
      }
    },
  );

  // Does nothing by itself. The AgentTemplate marks it requireApproval, so a
  // call becomes an approval request, which a2a-discord-gtw posts with an
  // @-mention: that request IS the notification. Approving or denying only
  // acknowledges it.
  server.tool(
    "notify_important",
    "Notify the user about important emails (administration or money). One call per run, listing every important email found.",
    NotifyImportantSchema.shape,
    () => Promise.resolve(textResult("The user has seen the notification.")),
  );

  server.tool(
    "create_folder",
    "Create a folder, at top level or inside a top-level non-system folder " +
      "(two levels at most). Returns the new folder's id, or the existing " +
      "one if a folder of that name is already there.",
    CreateFolderSchema.shape,
    async ({ name, parentId: parent }: z.infer<typeof CreateFolderSchema>) => {
      const parentId = parent ?? null;
      try {
        const [existing] = await connection.client.api.Mailbox.get({
          accountId: connection.accountId,
          properties: ["id", "name", "parentId"],
        });
        const same = existing.list.find((mb) =>
          (mb.parentId ?? null) === parentId &&
          mb.name.toLowerCase() === name.toLowerCase()
        );
        if (same) return textResult({ id: same.id, created: false });

        const [result] = await connection.client.api.Mailbox.set({
          accountId: connection.accountId,
          create: { new: { name, parentId, isSubscribed: true } },
        });
        const id = result.created?.new?.id;
        if (!id) {
          return {
            ...textResult({ notCreated: result.notCreated }),
            isError: true,
          };
        }
        mailboxCount++;
        if (parentId === null) parentIds.add(id);
        return textResult({ id, created: true });
      } catch (error) {
        return {
          ...textResult(`Error creating folder: ${(error as Error).message}`),
          isError: true,
        };
      }
    },
  );
};

const connection = await connectJmap({
  sessionUrl: `${internalOrigin}/jmap/session`,
  bearerToken: "replaced-by-guardedFetch",
  accountId: Deno.env.get("JMAP_ACCOUNT_ID"),
});

const [mailboxes] = await connection.client.api.Mailbox.get({
  accountId: connection.accountId,
  properties: ["id", "role", "name", "parentId"],
});
for (const mb of mailboxes.list) {
  if (mb.role && BLOCKED_ROLES.has(mb.role)) blockedMailboxIds.add(mb.id);
  if (!mb.parentId && !mb.role) parentIds.add(mb.id);
}
mailboxCount = mailboxes.list.length;
if (blockedMailboxIds.size === 0) {
  // Without these ids the Trash/Junk rule silently matches nothing.
  throw new Error("found no Trash or Junk mailbox; refusing to start");
}

// Stateless: a fresh server and transport per request, sharing one JMAP
// connection. Nothing here needs an MCP session.
const handleMcp = async (req: Request): Promise<Response> => {
  const server = new McpServer({ name: "jmap", version: deno.version });
  registerAllowedTools(server, connection);
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await server.connect(transport);
  return transport.handleRequest(req);
};

// Shared with the RemoteMCPServer, whose header kagent's egress gateway injects.
// Without it, anything that can open a connection to this pod could read the
// mailbox, and a gVisor sandbox on the same node arrives with the same `host`
// identity the kubelet's probes do, so the network policy cannot tell them
// apart.
const mcpAuthorization = `Bearer ${env("MCP_TOKEN")}`;

// PORT only so a second copy can run beside the server for testing the guard
// in-cluster (`kubectl exec`); Deno's --allow-net still has to admit it.
const port = Number(Deno.env.get("PORT") ?? "8080");

Deno.serve({ hostname: "0.0.0.0", port }, (req) => {
  const { pathname } = new URL(req.url);
  if (pathname === "/healthz") return new Response("ok");
  if (pathname !== "/mcp") return new Response("not found", { status: 404 });
  if (req.headers.get("authorization") !== mcpAuthorization) {
    return new Response("unauthorized", { status: 401 });
  }
  return handleMcp(req);
});
