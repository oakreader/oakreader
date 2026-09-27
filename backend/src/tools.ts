/**
 * The tools that touch this machine rather than the app: bash, read, write.
 *
 * They live here because nothing in them is macOS — they run a command and
 * move bytes, which is the same everywhere — while the rest of the agent's
 * tools read the open document, the live DOM, or the library, and could only
 * ever run in the shell.
 *
 * The shell still decides *whether* a call happens. It receives the model's
 * tool call, shows it, asks the user when the permission level says to, and
 * only then asks for it to be run. Keeping the approving side and the
 * executing side the same is deliberate: a design where the core executes and
 * merely asks permission first is one dropped message away from running an
 * unapproved command.
 */
import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { dirname, isAbsolute, resolve, sep } from "node:path";

/** How much output a tool may return before it is cut. */
const MAX_OUTPUT = 100_000;

/** Seconds a command may run before it is killed. */
const DEFAULT_TIMEOUT = 120;

export interface ToolResult {
  content: string;
  isError: boolean;
}

const ok = (content: string): ToolResult => ({ content, isError: false });
const fail = (content: string): ToolResult => ({ content, isError: true });

/** Risk, which is what the shell's permission levels gate on. */
export type ToolCategory = "readOnly" | "write" | "dangerous";

export interface ToolDefinition {
  name: string;
  description: string;
  category: ToolCategory;
  inputSchema: Record<string, unknown>;
}

export const PORTABLE_TOOLS: ToolDefinition[] = [
  {
    name: "read",
    category: "readOnly",
    description:
      "Read the contents of a file at the given path. Optionally specify offset "
      + "(line number to start from, 1-based) and limit (number of lines to read). "
      + "Returns the file text with line numbers.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute or relative path to the file to read." },
        offset: { type: "string", description: "Line number to start reading from (1-based). Defaults to 1." },
        limit: { type: "string", description: "Maximum number of lines to read. Defaults to all." },
      },
      required: ["path"],
    },
  },
  {
    name: "write",
    category: "write",
    description:
      "Write content to a file at the given path. Creates parent directories if "
      + "needed. Overwrites the file if it already exists.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute or relative path to the file to write." },
        content: { type: "string", description: "The text content to write to the file." },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "bash",
    category: "dangerous",
    description:
      "Execute a bash command. The command runs in the working directory. Use this "
      + "for git operations, running tests, installing packages, and other terminal tasks.",
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", description: "The bash command to execute." },
        timeout: { type: "string", description: "Timeout in seconds (default: 120)." },
      },
      required: ["command"],
    },
  },
];

/** Cut long output, saying so, rather than returning a wall of text. */
function truncate(text: string): string {
  if (text.length <= MAX_OUTPUT) return text;
  return `${text.slice(0, MAX_OUTPUT)}\n\n[output truncated at ${MAX_OUTPUT} characters]`;
}

/**
 * Resolve a path and confirm it is inside the sandbox.
 *
 * Compares path *segments*, not string prefixes. The Swift version this
 * replaces asked `url.path.hasPrefix(allowedPath)`, which let
 * `/Users/me/OakReader-Dev-elsewhere` pass a sandbox of
 * `/Users/me/OakReader-Dev`: a sibling directory whose name merely starts the
 * same way is not inside it.
 *
 * An empty allow-list means unsandboxed, which is how the shell asks for a
 * workspace with no restriction.
 */
export function resolveInSandbox(
  path: string, workingDirectory: string, allowedPaths: string[],
): string | null {
  const absolute = resolve(isAbsolute(path) ? path : resolve(workingDirectory, path));
  if (allowedPaths.length === 0) return absolute;

  for (const allowed of allowedPaths) {
    const root = resolve(allowed);
    if (absolute === root || absolute.startsWith(root.endsWith(sep) ? root : root + sep)) {
      return absolute;
    }
  }
  return null;
}

async function runRead(
  args: Record<string, string>, workingDirectory: string, allowedPaths: string[],
): Promise<ToolResult> {
  const path = args.path;
  if (path === undefined) return fail("Missing required parameter: path");

  const resolved = resolveInSandbox(path, workingDirectory, allowedPaths);
  if (resolved === null) return fail("Access denied: path is outside allowed directories");

  let text: string;
  try {
    text = await readFile(resolved, "utf8");
  } catch (error) {
    return fail(`Failed to read file: ${error instanceof Error ? error.message : error}`);
  }

  const lines = text.split("\n");
  const offset = Number.parseInt(args.offset ?? "1", 10) || 1;
  const start = Math.max(0, offset - 1);
  if (start >= lines.length) {
    return fail(`Offset ${offset} exceeds file length (${lines.length} lines)`);
  }

  const limit = Number.parseInt(args.limit ?? "", 10);
  const end = Number.isInteger(limit) ? Math.min(lines.length, start + limit) : lines.length;

  // Line numbers are what let the model quote a location back.
  const numbered = lines.slice(start, end)
    .map((line, index) => `${start + index + 1}\t${line}`)
    .join("\n");
  return ok(truncate(numbered));
}

async function runWrite(
  args: Record<string, string>, workingDirectory: string, allowedPaths: string[],
): Promise<ToolResult> {
  const path = args.path;
  const content = args.content;
  if (path === undefined) return fail("Missing required parameter: path");
  if (content === undefined) return fail("Missing required parameter: content");

  const resolved = resolveInSandbox(path, workingDirectory, allowedPaths);
  if (resolved === null) return fail("Access denied: path is outside allowed directories");

  try {
    await mkdir(dirname(resolved), { recursive: true });
    await writeFile(resolved, content);
  } catch (error) {
    return fail(`Failed to write file: ${error instanceof Error ? error.message : error}`);
  }
  return ok(`Successfully wrote ${content.length} characters to ${resolved}`);
}

async function runBash(
  args: Record<string, string>, workingDirectory: string,
): Promise<ToolResult> {
  const command = args.command;
  if (command === undefined) return fail("Missing required parameter: command");

  const seconds = Number.parseFloat(args.timeout ?? "") || DEFAULT_TIMEOUT;

  // The directory may not exist yet — a workspace is created lazily — and
  // spawning into a missing cwd fails with an error about the wrong thing.
  const cwd = await stat(workingDirectory).then((s) => s.isDirectory()).catch(() => false)
    ? workingDirectory : process.cwd();

  const child = Bun.spawn(["/bin/bash", "-lc", command], {
    cwd, stdout: "pipe", stderr: "pipe",
  });

  const timer = setTimeout(() => child.kill(), seconds * 1000);
  try {
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    // Combined, in the order a terminal would have shown them.
    const output = truncate([stdout, stderr].filter((s) => s !== "").join("\n").trimEnd());
    return exitCode === 0 ? ok(output) : fail(`Exit code: ${exitCode}\n${output}`);
  } catch (error) {
    return fail(`Failed to execute command: ${error instanceof Error ? error.message : error}`);
  } finally {
    clearTimeout(timer);
  }
}

export async function runTool(
  name: string,
  args: Record<string, string>,
  workingDirectory: string,
  allowedPaths: string[],
): Promise<ToolResult> {
  switch (name) {
    case "read":  return await runRead(args, workingDirectory, allowedPaths);
    case "write": return await runWrite(args, workingDirectory, allowedPaths);
    case "bash":  return await runBash(args, workingDirectory);
    default:      return fail(`Unknown tool: ${name}`);
  }
}
