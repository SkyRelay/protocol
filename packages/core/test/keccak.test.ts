import assert from "node:assert/strict";
import { test } from "node:test";
import { keccak256Hex, utf8 } from "../src/crypto/keccak.ts";

test("keccak256 empty string (Ethereum)", () => {
  assert.equal(
    keccak256Hex(utf8("")),
    "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
  );
});

test("keccak256 of abc (Ethereum)", () => {
  assert.equal(
    keccak256Hex(utf8("abc")),
    "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
  );
});
