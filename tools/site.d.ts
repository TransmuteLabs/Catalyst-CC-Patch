// THE CONTRACT OF THE SPLICE SITE.
//
// The block is spliced into someone else's scope, so every name it does not
// declare itself has to come from there. Listing them is the point: an
// undeclared name is a ReferenceError on whichever line finally runs, and the
// lines that reach for host globals are failure handlers -- the ones nobody
// exercises until they matter.
//
// Types are deliberately loose. This file is not here to type the product; it
// is here so that "the name exists" is a compiler question instead of a
// human's memory.

// --- captured from the image by the patcher's locators ---
declare const QM: ((args: any) => Promise<any>) | undefined;  // single-shot query engine
declare const TV: (payload: any) => void;                     // notification queue
declare const DI: () => string;                               // session id
declare const TTL: (entry: any) => string | undefined;        // session title

// --- the slots each site binds ($1..$5 before resolution) ---
declare const __slot1: any, __slot2: { name: string }, __slot3: any,
              __slot4: any, __slot5: any;

// --- host globals the block relies on ---
declare const process: any;
declare const Buffer: any;
declare const fetch: (input: any, init?: any) => Promise<any>;
declare class AbortController { signal: any; abort(): void; }
declare function setTimeout(handler: (...a: any[]) => void, ms?: number): any;
declare function clearTimeout(handle: any): void;
declare const console: { error(...a: any[]): void; log(...a: any[]): void };

// Loaded with a dynamic import at the moment they are needed, so that a build
// without them degrades instead of failing to start.
declare module "node:fs/promises" { const m: any; export = m; }
declare module "node:zlib" { const m: any; export = m; }
