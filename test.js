// Kompiliert ClearingCoin.sol und testet das Regelwerk auf einer lokalen Ganache-Chain.
const fs = require("fs");
const solc = require("solc");
process.removeAllListeners("unhandledRejection");
const ganache = require("ganache");
const { ethers } = require("ethers");
const assert = require("assert");

const src = fs.readFileSync(__dirname + "/ClearingCoin.sol", "utf8");
const out = JSON.parse(solc.compile(JSON.stringify({
  language: "Solidity",
  sources: { "ClearingCoin.sol": { content: src } },
  settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: "shanghai",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
})));
const errs = (out.errors || []).filter(e => e.severity === "error");
if (errs.length) { console.error(errs.map(e => e.formattedMessage).join("\n")); process.exit(1); }
const C = out.contracts["ClearingCoin.sol"].ClearingCoin;

const E = (n) => ethers.parseEther(String(n));
const DAY = 86400;

(async () => {
  const provider = new ethers.BrowserProvider(ganache.provider({ wallet: { deterministic: true }, logging: { quiet: true }, chain: { hardfork: "shanghai" } }));
  // Ganache schätzt Gas bei zeitabhängigem Code leicht zu niedrig -> 30 % Puffer
  const est = provider.estimateGas.bind(provider);
  provider.estimateGas = async (tx) => (await est(tx)) * 13n / 10n;
  const [admin, A, B, Cc, agent] = await Promise.all([0, 1, 2, 3, 4].map(i => provider.getSigner(i)));
  const time = async (s) => { await provider.send("evm_increaseTime", [s]); await provider.send("evm_mine", []); };
  const reverts = async (fn, name) => {
    try { await fn(); } catch (e) { return; }
    throw new Error("expected revert: " + name);
  };

  const params = {
    tier1Bps: 2500, tier2Bps: 5000, rate1Bps: 100, rate2Bps: 200,
    maxSurplusBps: 20000, quotaFactorBps: 2500, turnoverWindow: 365 * DAY,
    gracePeriod: 30 * DAY, maxQuota: E(10_000_000),
  };
  const f = new ethers.ContractFactory(C.abi, C.evm.bytecode.object, admin);
  const clc = await f.deploy(await admin.getAddress(), params);
  await clc.waitForDeployment();
  const [a, b, c, ag] = await Promise.all([A, B, Cc, agent].map(s => s.getAddress()));
  const POOL = await clc.POOL();

  const sum = async () => {
    let s = 0n;
    for (const x of [a, b, c, POOL]) s += (await clc.accounts(x)).balance;
    return s;
  };

  for (const x of [a, b, c]) await (await clc.admit(x, E(1_000_000))).wait();
  console.log("✓ R1 Zulassung");

  // R6: Kreditlinie
  await (await clc.connect(A).transfer(b, E(900_000), ethers.ZeroHash)).wait();
  await reverts(() => clc.connect(A).transfer.staticCall(c, E(200_000), ethers.ZeroHash), "CreditLimitExceeded");
  assert.equal(await sum(), 0n);
  console.log("✓ R2 Nullsumme / R6 Kreditlinie");

  // R4: symmetrische Gebühr nach 1 Jahr
  await time(365 * DAY);
  const feeA = await clc.pendingFee(a), feeB = await clc.pendingFee(b);
  // Quote nach Umsatz: max(1M, 25% * 900k) = 1M. Band 250k-500k @1% + 400k @2% = 2.5k + 8k = 10.5k
  const near = (x) => assert.ok(x >= E(10_500) && x < E(10_501), String(x)); near(feeA); near(feeB);
  await (await clc.poke(a)).wait(); await (await clc.poke(b)).wait();
  assert.ok((await clc.poolBalance()) >= E(21_000));
  assert.equal(await sum(), 0n);
  console.log("✓ R4 Gebühr auf Guthaben UND Schulden, Pool:", ethers.formatEther(await clc.poolBalance()));

  // R5: Überschuss-Deckel (200 % der Quote)
  await (await clc.connect(Cc).transfer(b, E(1_000_000), ethers.ZeroHash)).wait();
  // B hat ~1.889M, Cap = 2M (Quote 1M -> evtl. höher durch Umsatz). Weitere große Zahlung blockiert:
  await (await clc.admit(ag, E(5_000_000))).wait();
  await reverts(() => clc.connect(agent).transfer.staticCall(b, E(2_000_000), ethers.ZeroHash), "SurplusCapExceeded");
  console.log("✓ R5 Überschuss-Deckel");

  // R10: Netting – Kreisforderung, die einzeln das Limit sprengen würde
  for (const s of [A, B, Cc]) await (await clc.connect(s).setClearingConsent(true)).wait();
  const before = (await clc.accounts(a)).balance;
  await (await clc.settleBatch([
    { from: a, to: c, amount: E(500_000), ref: ethers.ZeroHash },
    { from: b, to: a, amount: E(500_000), ref: ethers.ZeroHash },
  ], ethers.id("batch-1"))).wait();
  const d = (await clc.accounts(a)).balance - before;
  assert.ok(d <= 0n && d > -E(1)); // nur Gebühren-Sekunden, Netto-Position unverändert
  await reverts(() => clc.connect(A).transfer.staticCall(c, E(500_000), ethers.ZeroHash), "CreditLimitExceeded"); // einzeln unmöglich
  console.log("✓ R10 multilaterales Netting");

  // R9: Agenten-Mandat
  const now = (await provider.getBlock("latest")).timestamp;
  await (await clc.connect(B).setMandate(ag, E(1_000), E(2_500), DAY, now + 30 * DAY, true)).wait();
  await (await clc.connect(B).setMandateCounterparty(ag, c, true)).wait();
  await (await clc.connect(agent).agentPay(b, c, E(1_000), ethers.id("PO-1"))).wait();
  await (await clc.connect(agent).agentPay(b, c, E(1_000), ethers.id("PO-2"))).wait();
  await reverts(() => clc.connect(agent).agentPay.staticCall(b, c, E(1_000), ethers.id("PO-3")), "MandateLimit");
  await reverts(() => clc.connect(agent).agentPay.staticCall(b, a, E(100), ethers.id("PO-4")), "InvalidCounterparty");
  await time(DAY);
  await (await clc.connect(agent).agentPay(b, c, E(1_000), ethers.id("PO-5"))).wait();
  await (await clc.connect(B).revokeMandate(ag)).wait();
  await reverts(() => clc.connect(agent).agentPay.staticCall(b, c, E(1), ethers.id("PO-6")), "MandateInvalid");
  console.log("✓ R9 Agenten-Mandate");

  // R7: Ausfall & Abschreibung
  await reverts(() => clc.writeOff.staticCall(a), "NotEligible");
  await (await clc.setFrozen(a, true)).wait();
  await reverts(() => clc.connect(A).transfer.staticCall(b, E(1), ethers.ZeroHash), "AccountFrozen");
  await time(31 * DAY);
  const debt = (await clc.accounts(a)).balance;
  await (await clc.writeOff(a)).wait();
  assert.equal((await clc.accounts(a)).balance, 0n);
  assert.equal(await clc.lossesWrittenOff(), -debt);
  assert.equal(await sum() + (await clc.accounts(ag)).balance, 0n);
  console.log("✓ R7 Abschreibung, Pool jetzt:", ethers.formatEther(await clc.poolBalance()));

  // R11: Timelock
  await (await clc.proposeParams({ ...params, rate2Bps: 300 })).wait();
  await reverts(() => clc.executeParams.staticCall(), "TimelockActive");
  await reverts(() => clc.proposeParams.staticCall({ ...params, rate2Bps: 5000 }), "InvalidParams");
  await time(2 * DAY);
  await (await clc.executeParams()).wait();
  assert.equal((await clc.params()).rate2Bps, 300n);
  console.log("✓ R11 Timelock + harte Grenzen");

  // R12: Notbremse
  await (await clc.pause()).wait();
  await reverts(() => clc.connect(B).transfer.staticCall(c, E(1), ethers.ZeroHash), "IsPaused");
  await (await clc.unpause()).wait();
  console.log("✓ R12 Pause");

  // R13: Austritt nur bei 0
  await reverts(() => clc.connect(B).exit.staticCall(), "BalanceNotZero");
  console.log("✓ R13 Austritt");

  console.log("\nAlle Tests bestanden. Summe aller Salden:", (await sum() + (await clc.accounts(ag)).balance).toString());
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
