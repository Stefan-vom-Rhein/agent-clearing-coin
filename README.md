# agent-clearing-coin

Symmetrische Clearing-Währung nach Keynes' Bancor-Prinzip, als Smart Contract für internationalen B2B-Handel und die Machine-to-Machine-Ökonomie (KI-Agenten).

Kernidee: Kein Mint. Geld entsteht als gegenseitiger Kredit, die Summe aller Salden ist immer 0. Gebühren treffen **Überschüsse und Defizite** gleichermaßen, damit sich keine Liquiditätsberge in einzelnen Bilanzen aufstauen.

## Regelwerk (Kurzfassung)

| # | Regel |
|---|-------|
| R1 | Nur zugelassene Teilnehmer (KYB), Agenten nur per Mandat |
| R2 | Kein Mint, Summe aller Salden = 0 |
| R3 | Kreditlinie = max(Basisquote, 25 % des Umsatzes), gedeckelt |
| R4 | Gebühr auf Guthaben **und** Schulden: 1 % p.a. über 25 %, 2 % p.a. über 50 % der Quote |
| R5 | Überschuss-Deckel bei 200 % der Quote |
| R6 | Ausgaben nur innerhalb der Kreditlinie |
| R7 | Ausfall: Abschreibung nach 30 Tagen, Verlust trägt der Pool |
| R8 | Pool-Mittel nur zum Schuldenabbau |
| R9 | Agenten-Mandate: Limits pro Tx/Periode, Ablauf, Gegenpartei-Whitelist |
| R10 | Multilaterales Netting durch Clearing-Operator |
| R11 | Parameteränderungen nur mit 2-Tage-Timelock und harten Grenzen |
| R12 | Notbremse: Guardian pausiert, Governor entpausiert |
| R13 | Austritt nur bei Saldo 0 |

Details stehen im Kopf von [`ClearingCoin.sol`](ClearingCoin.sol).

## Testen

```bash
npm install
npm test
```

## Bekannte Restrisiken

- Wash-Trading kann die Umsatz-Quote aufblähen (begrenzt durch `maxQuota` und `quotaFactor`).
- Parameteränderungen wirken auf noch nicht abgerechnete Zeiträume, daher vorher `poke()` ausführen.
- ADMIN- und GOVERNOR-Rollen sollten in Produktion Multisig- oder DAO-Verträge sein.

Status: Prototyp, nicht auditiert.
