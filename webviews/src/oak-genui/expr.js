// A small, side-effect-free expression language for genui bindings.
//
// ChatGPT's v1 widgets bind props to state with CEL; this is the same idea at
// the size a model can be taught in one paragraph. It is parsed, never passed
// to eval or Function: widget JSON comes from a model, and nothing it writes
// may reach the page's globals.
//
// Grammar: literals (number, 'string', "string", true, false, null), paths
// (state.a.b, item.x, a[0]), unary ! -, binary * / % + - < <= > >= == != && ||,
// ternary ?:, and calls to the functions in FUNCTIONS.

const FUNCTIONS = {
  len: (v) => (v == null ? 0 : typeof v === "string" || Array.isArray(v) ? v.length : Object.keys(v).length),
  round: (x, n = 0) => {
    const f = 10 ** Number(n);
    return Math.round(Number(x) * f) / f;
  },
  floor: (x) => Math.floor(Number(x)),
  ceil: (x) => Math.ceil(Number(x)),
  abs: (x) => Math.abs(Number(x)),
  min: (...xs) => Math.min(...flatten(xs).map(Number)),
  max: (...xs) => Math.max(...flatten(xs).map(Number)),
  sum: (list, key) => (Array.isArray(list) ? list : []).reduce((a, v) => a + Number(key ? v?.[key] : v) || a, 0),
  number: (x) => Number(x),
  string: (x) => (x == null ? "" : String(x)),
  format: (x, spec = "") => format(x, String(spec)),
  join: (list, sep = ", ") => (Array.isArray(list) ? list.join(sep) : ""),
  contains: (hay, needle) => (Array.isArray(hay) ? hay.includes(needle) : String(hay ?? "").includes(String(needle))),
};

function flatten(xs) {
  return xs.flatMap((x) => (Array.isArray(x) ? x : [x]));
}

function format(x, spec) {
  const n = Number(x);
  if (spec.startsWith("currency:")) {
    const currency = spec.slice(9) || "USD";
    try {
      return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(n);
    } catch {
      return `${n.toFixed(2)} ${currency}`;
    }
  }
  if (spec === "percent") return new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 }).format(n);
  const decimals = /^0\.(0+)$/.exec(spec);
  if (decimals) return n.toFixed(decimals[1].length);
  if (spec === "0") return Math.round(n).toString();
  return Number.isFinite(n) ? new Intl.NumberFormat().format(n) : String(x ?? "");
}

function tokenize(src) {
  const tokens = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (/\s/.test(c)) {
      i++;
      continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src[i + 1]))) {
      const m = /^[0-9]*\.?[0-9]+(e[+-]?[0-9]+)?/i.exec(src.slice(i));
      tokens.push({ t: "num", v: Number(m[0]) });
      i += m[0].length;
      continue;
    }
    if (c === "'" || c === '"') {
      let j = i + 1;
      let s = "";
      while (j < src.length && src[j] !== c) {
        if (src[j] === "\\" && j + 1 < src.length) j++;
        s += src[j++];
      }
      if (j >= src.length) throw new Error("unterminated string");
      tokens.push({ t: "str", v: s });
      i = j + 1;
      continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(i));
      tokens.push({ t: "id", v: m[0] });
      i += m[0].length;
      continue;
    }
    const two = src.slice(i, i + 2);
    if (["<=", ">=", "==", "!=", "&&", "||"].includes(two)) {
      tokens.push({ t: "op", v: two });
      i += 2;
      continue;
    }
    if ("+-*/%<>!?:.,()[]".includes(c)) {
      tokens.push({ t: "op", v: c });
      i++;
      continue;
    }
    throw new Error(`unexpected '${c}'`);
  }
  return tokens;
}

const BINARY = {
  "||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6,
};

function parse(src) {
  const tokens = tokenize(src);
  let pos = 0;
  const peek = () => tokens[pos];
  const isOp = (v) => peek()?.t === "op" && peek().v === v;
  const expect = (v) => {
    if (!isOp(v)) throw new Error(`expected '${v}'`);
    pos++;
  };

  function primary() {
    const tok = tokens[pos++];
    if (!tok) throw new Error("unexpected end");
    if (tok.t === "num" || tok.t === "str") return { k: "lit", v: tok.v };
    if (tok.t === "op" && tok.v === "(") {
      const e = expression(0);
      expect(")");
      return e;
    }
    if (tok.t === "op" && (tok.v === "!" || tok.v === "-")) return { k: "un", op: tok.v, a: unary() };
    if (tok.t === "id") {
      if (tok.v === "true") return { k: "lit", v: true };
      if (tok.v === "false") return { k: "lit", v: false };
      if (tok.v === "null") return { k: "lit", v: null };
      if (isOp("(")) {
        pos++;
        const args = [];
        while (!isOp(")")) {
          args.push(expression(0));
          if (!isOp(")")) expect(",");
        }
        pos++;
        return { k: "call", name: tok.v, args };
      }
      return { k: "var", name: tok.v };
    }
    throw new Error(`unexpected '${tok.v}'`);
  }

  function unary() {
    let node = primary();
    for (;;) {
      if (isOp(".")) {
        pos++;
        const id = tokens[pos++];
        if (id?.t !== "id") throw new Error("expected a name after '.'");
        node = { k: "get", obj: node, key: { k: "lit", v: id.v } };
      } else if (isOp("[")) {
        pos++;
        const key = expression(0);
        expect("]");
        node = { k: "get", obj: node, key };
      } else {
        return node;
      }
    }
  }

  function expression(minPrec) {
    let left = unary();
    for (;;) {
      const tok = peek();
      if (tok?.t === "op" && tok.v === "?" && minPrec === 0) {
        pos++;
        const yes = expression(0);
        expect(":");
        const no = expression(0);
        left = { k: "if", c: left, a: yes, b: no };
        continue;
      }
      const prec = tok?.t === "op" ? BINARY[tok.v] : undefined;
      if (prec === undefined || prec <= minPrec) return left;
      pos++;
      left = { k: "bin", op: tok.v, a: left, b: expression(prec) };
    }
  }

  const tree = expression(0);
  if (pos !== tokens.length) throw new Error(`unexpected '${tokens[pos].v}'`);
  return tree;
}

function run(node, scope) {
  switch (node.k) {
    case "lit":
      return node.v;
    case "var":
      return Object.prototype.hasOwnProperty.call(scope, node.name) ? scope[node.name] : undefined;
    case "get": {
      const obj = run(node.obj, scope);
      const key = run(node.key, scope);
      if (obj == null) return undefined;
      // Own data only: no prototype walk, so `__proto__` or `constructor` read nothing.
      return Object.prototype.hasOwnProperty.call(obj, key) ? obj[key] : undefined;
    }
    case "un": {
      const a = run(node.a, scope);
      return node.op === "!" ? !a : -Number(a);
    }
    case "if":
      return run(node.c, scope) ? run(node.a, scope) : run(node.b, scope);
    case "call": {
      const fn = FUNCTIONS[node.name];
      if (!fn) throw new Error(`unknown function ${node.name}`);
      return fn(...node.args.map((a) => run(a, scope)));
    }
    case "bin": {
      if (node.op === "&&") return run(node.a, scope) && run(node.b, scope);
      if (node.op === "||") return run(node.a, scope) || run(node.b, scope);
      const a = run(node.a, scope);
      const b = run(node.b, scope);
      switch (node.op) {
        case "+":
          return typeof a === "string" || typeof b === "string" ? `${a ?? ""}${b ?? ""}` : Number(a) + Number(b);
        case "-": return Number(a) - Number(b);
        case "*": return Number(a) * Number(b);
        case "/": return Number(a) / Number(b);
        case "%": return Number(a) % Number(b);
        case "<": return a < b;
        case "<=": return a <= b;
        case ">": return a > b;
        case ">=": return a >= b;
        case "==": return a == b; // eslint-disable-line eqeqeq -- "3" == 3 is what a model means
        case "!=": return a != b; // eslint-disable-line eqeqeq
      }
    }
  }
  throw new Error("bad expression");
}

const cache = new Map();

/** Evaluate `src` against `scope`. Throws on a parse or evaluation error. */
export function evaluate(src, scope) {
  let tree = cache.get(src);
  if (!tree) {
    tree = parse(src);
    cache.set(src, tree);
  }
  return run(tree, scope);
}

/** Replace `{expr}` spans in a string with their values. A bad span is left as typed. */
export function interpolate(text, scope) {
  return String(text).replace(/\{([^{}]+)\}/g, (whole, src) => {
    try {
      const v = evaluate(src, scope);
      return v == null ? "" : String(v);
    } catch {
      return whole;
    }
  });
}
