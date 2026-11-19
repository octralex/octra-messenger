# Capabilities and limits

Status: maintainer v2 revision under design and independent review. The native recipient controls, protocol tests,
binary I/O tests and disposable devnet circle feasibility are lab evidence only. The realtime demo, production
messenger and external sync remain unapproved and unbuilt. Independent review, chain-integrated contact/policy,
encrypted secret persistence and larger/interference benchmarks remain open.

## Implementation and native pins

- Implementation: `projects/onchain-messenger/` in `octralex/octra-egregore`, built and tested only on Hetzner.
- lite_node review/build pin: `8f785a93a4e7392a0f3e65674f9de89854d33dbc`.
- Webcli source pin: `28208507bf704b9d2726dd48cb6597319c594688`; deployed executable SHA-256
  `93702748d072725ebebf564c55bf35b38ecb481bad4c09f02fef6520e3e6db3a`.
- PVAC library reference hash `fc72588467f5e84f34323de51b50b83bd8cb74c7b91b2cbfb7c150a365984357`.
  The same-key PVAC message path is removed; this artifact is not a recipient-encryption substitute.
- OCaml 4.14.2, dune 3.23.0 and Mirage 2.1.0 from the node switch. No external messaging dependency, browser UI,
  WebSocket service or non-OCaml messenger service is used.
- Isolated venue `/srv/octra-node/fakenet-kimi-messenger/`, with synthetic identities only. The live validator,
  updater, shared fakenet, fleet identities and production wallets are not used by the library tests.

## Measured source limits at the pin

| Limit | Observed value | Consequence |
| --- | ---: | --- |
| Ordinary transfer message | 256 bytes | Not a messenger transport. |
| Program message field | 10,000,000 bytes | Not an end-to-end payload guarantee. |
| Transaction gossip JSON | 5,000,000 bytes | JSON and signature overhead must be included. |
| Program execution lane | 128 transactions, 4 MiB, 10,000,000 OU per budget | Requires multi-node measurement. |
| Contract storage value | 4,194,304 bytes | A whole large envelope is not one accepted frame. |
| Circle inline value | 65,536 bytes | The selected app frame is smaller; this is not an absolute write benchmark. |
| Circle stable storage | 33,554,432 bytes | Requires retention and rollover tests before scale claims. |
| View call | 10 second RPC deadline, singleton busy guard | Feed paging needs explicit budgets and backpressure. |
| Storage snapshot RPC | Owner-authorized; public circle view is separate | Cross-device public history uses `octra_circleView`, not an owner secret. |

Source anchors: `lib/core/tx_payload.ml`, `net/p2p_tx_gossip.ml`, `lib/core/resource_lanes.ml`,
`lib/core/circles.ml`, `lib/vm/runtime/contract_vm.ml`, `lib/vm/rpc/contract_rpc.ml` and
`node_runtime/circle_read_rpc.ml`.

## Native v2 implementation

- One `octra_messenger` library depends on `octra_net` and `octra_core`; the core is private and the testkit is a
  separate test-only library. Public modules have `.mli` interfaces and SPDX headers. No modules are copied into
  `lite_node/test`.
- `Oce1` supplies canonical fields and bounded reads; `Hash_domain` supplies tagged SHA-256 for signatures, AD,
  replay, storage and fixtures. HMAC-SHA256 is used only for key derivation.
- A 194-byte header carries explicit codec version, sender sequence, sender epoch and a 16-byte sender instance.
  Only v2 readers and writers exist; v1 rewraps and old tags reject. One application-bearing `Session_context`
  preserves version and uses OCE1, giving 86-byte context and 308-byte overhead including nonce/tag.
- Expected sender keys are resolved by contact wallet address before signature verification. Messages use the
  wallet Ed25519 key and `octra:msg:sig:v2`, not transaction serialization. The default receive cap is 64 KiB;
  the encoding cap is 3,000,000 bytes and is not safe chat parsing or large-message storage.
- Per-contact monotonic sequences and random sender instances prevent cross-contact and same-wallet device replay
  collisions. Any forward jump advances a permanent 1,024-bit channel window. Outbox allocations persist before
  sealing and record IDs disambiguate retries. Sequences are positive signed 64-bit values with an explicit
  `exhausted` terminal state; invalid counters cannot wrap or rotate. Verified-high-water recovery only advances
  the counter while preserving the instance and pending records. Windows are never pruned; growth across
  channels/rotations requires an operational migration policy.
- Live acceptance is at most 64 epochs old and two ahead. Archive uses the frame's commit epoch and rejects only a
  later sender epoch, while retaining signature, replay and atomic-persistence checks.
- Per-user segment and registry bytecode embed the owner because native circle deployment does not run the AML
  constructor. Appends accept that owner or granted writers and store `caller`; the client binds it to the contact
  wallet and fixed-header sender key before full decoding. Non-owner writes reject without mutation.
- Tagged typed-key loading and atomic writes live in `Recipient_keys`; raw construction is not exported. Secret
  files and per-message plaintext are mode 0600 but not encrypted at rest.

## Evidence

- The endpoint covers expected-sender failure, low-order/malformed points, typed keys, RNG failure, wrong recipients,
  modified header/body/signature, v1 rewraps, replay after pruning, large forward jumps, out-of-order and
  outside-window sequences, restart rollback, stale/future epochs, archive commit epochs, concurrent duplicates,
  two-device identity, 1,025 other-contact sends, incomplete outbox allocations, malformed state and downgrade
  rejection.
- Standalone protocol: 5,001 frame cases plus native tagged split digests, canonical context/cursor versions and
  bounded pages. Binary I/O: both ABI routes, wrong shapes, duplicates, canonical pad bits, empty/ASCII/invalid
  output and split-multibyte truncation. That older lab profile is separate from the current recipient evidence;
  storage keys remain raw strings.
- Segment and registry controls cover both compiler profiles, owner/granted writers, non-owner publish/append,
  exact deduplication, descriptors, restart and close. Native circle deployment does not run the AML constructor,
  so owner-specific bytecode is required and tested.
- Historical devnet feasibility at `815afb913` confirms an owner-specific deployment and a 2,048-byte base64-text
  write. Public views return the embedded owner, matching stored caller and exact 372-byte v2 envelope; archive
  decryption recovers the 64-byte plaintext using the frame's commit epoch, without an owner-secret read or lab patch.
  A 2,050-byte append rejects; an earlier note mislabelled that control as 2,049 bytes. Signed JSON sizes are 4,021
  deploy and 2,462 write; RPC requests are 4,081 and 2,522. OU base costs are 200,000/1,000, not explicit fee burn
  or throughput. See `receipts/chain/devnet-feasibility.json` and the separate OCPG revision evidence.
- Historical isolated registry rollover, pruning, index rebuild, fresh sync and 100-frame results remain bound to
  their original layout. They are not silently rebound to the new segment, context or recipient profile. The prior
  100-frame whole-node growth was about 9.8–10.8 KB per frame across 14 points, not a message-only amplification
  factor or sustainable-rate result.

## Current native gaps

1. **Design and independent review.** `docs/SCHEME.md` needs the maintainer design read before the demo is built
   on it.
2. **Contact and policy authority.** Contact registration is deferred to on-chain registration. Demo contact cards and local policy
   are not production trust roots. Client custody needs encrypted backup.
3. **Persistence and recovery.** Secret files and per-message plaintext are mode 0600 but not encrypted at rest.
   Secure backup, chain nonce allocation, production recovery and power-loss certification remain open. Crash
   orphans count against the byte cap until retried; ten authorized contacts can exhaust the global cap, and the
   receive path scans the whole directory.
4. **Chain format and completeness.** Large-message chunking, committed feed proofs, production cursor/finality
   semantics, registry/code-upgrade authorization and sustained client behavior remain unimplemented. Exact frame
   bodies are retained once; dedup uses the matching `octra:msg:frame:v2` digest. Registry descriptors use bounded
   OCE1 fields. The lab-only `\xHH` compiler-literal patch is pinned in `native/byte-literals.patch`; it adds no VM
   opcode or state-rule change and has not been accepted upstream. The separate
   `native/circle-typed-storage.patch` is also lab-only: it corrects typed storage initialization independently of
   nested-call permission. Unpatched Circle execution and devnet compatibility are not established.
5. **Retention and measurement.** Replay windows are permanent and grow across channels/rotations. A migration
   policy is required. 10,000/100,000-frame retention, revised pruning/fresh-sync evidence, sustained 1/10/100 fps,
   multi-client interference, explicit fee burn and storage/scheduler optimization remain open. Kernel/I/O
   experiments require separately measured isolated bottlenecks, not speculation.
6. **Security properties.** Forward secrecy, post-compromise recovery, recipient anonymity and post-quantum
   confidentiality are not established. Wallet signatures are public and non-deniable; leaked view secrets expose
   harvested ciphertext permanently. Stronger anonymity needs unlinkable authorization/fees and network anonymity.

New application work is limited to the v2 native binding, storage/replay, registry/segment/bootstrap and the
minimal demo client/relay after the design gate. No consensus opcode, state-root rule, fee change, external
messaging stack or upstream write is proposed. The first optimization candidate remains measured storage
allocation/serialization/scheduling; no kernel change is implied.
