// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  ClearingCoin (CLC)
 * @notice Symmetrische Clearing-Einheit für B2B-Handel und Machine-to-Machine-Ökonomie
 *         nach dem Vorbild von Keynes' Bancor / International Clearing Union.
 *
 * ============================== REGELWERK ==============================
 *
 * R1  Zulassung      Nur zugelassene Teilnehmer (KYB durch Rolle ADMISSION) halten ein Konto.
 *                    Maschinen/KI-Agenten handeln nie auf eigene Rechnung, sondern nur per
 *                    Mandat eines Teilnehmers (R9).
 *
 * R2  Kein Mint      Es gibt keine Ausgabe von Einheiten. Geld entsteht ausschließlich als
 *                    gegenseitiger Kredit: Wer zahlt, darf ins Minus gehen. Die Summe aller
 *                    Salden (inkl. Pool) ist IMMER exakt 0.
 *
 * R3  Quote          Kreditlinie = Quote = min(maxQuota, max(Basisquote, Umsatz-EMA × quotaFactor)).
 *                    Der Umsatz zerfällt linear über turnoverWindow. Die Limitprüfung einer
 *                    Zahlung nutzt die Quote VOR dieser Zahlung (keine Selbst-Hebelung).
 *
 * R4  Symm. Gebühr   Guthaben UND Schulden oberhalb tier1 (% der Quote) kosten rate1 p.a.,
 *                    oberhalb tier2 kosten sie rate2 p.a. Abrechnung sekundengenau und lazy
 *                    bei jeder Kontobewegung; poke() erlaubt jedem die Abrechnung inaktiver
 *                    Konten. Eine einzelne Abrechnung drückt den Betrag nie unter tier1.
 *
 * R5  Überschuss-    Optional (maxSurplusBps > 0): Zahlungen, die den Empfänger über
 *     Deckel         maxSurplus (% der Quote) heben, werden abgelehnt. Wer zu viel hortet,
 *                    muss ausgeben, bevor er weiter verkaufen kann.
 *
 * R6  Überziehung    Ausgehende Zahlungen nur innerhalb der Kreditlinie. Gebühren dürfen ein
 *                    Konto über die Linie drücken; dann sind nur noch Eingänge möglich.
 *
 * R7  Ausfall        Ist ein Konto länger als gracePeriod überzogen ODER eingefroren, kann der
 *                    GOVERNOR die Schuld abschreiben. Den Verlust trägt der Pool (Sozialisierung).
 *
 * R8  Pool           Alle Gebühren fließen in den Pool. Der Pool darf Mittel nur zum Abbau von
 *                    Schulden einsetzen, nie um Guthaben zu erzeugen. Ein negativer Pool
 *                    (nach Abschreibungen) wird durch künftige Gebühren aufgefüllt.
 *
 * R9  Agenten-       Mandat je Agent: Limit pro Transaktion, Limit pro Periode, Ablaufdatum,
 *     Mandate        optionale Gegenpartei-Whitelist. Der Teilnehmer kann jederzeit widerrufen.
 *
 * R10 Netting        Ein CLEARING-Operator darf multilaterale Batches einreichen, allerdings nur für
 *                    Teilnehmer mit Zustimmung (clearingConsent). Die Limits werden erst nach dem
 *                    gesamten Batch geprüft, damit sich Kreisforderungen gegenseitig aufheben können.
 *
 * R11 Governance     Parameter ändern sich nur über einen Timelock (2 Tage) und innerhalb harter
 *                    Grenzen im Code. Hinweis: Neue Parameter gelten für alle noch nicht
 *                    abgerechneten Zeiträume, daher vor executeParams() relevante Konten poken.
 *
 * R12 Notbremse      Der GUARDIAN kann nur pausieren, entpausieren kann nur der GOVERNOR.
 *
 * R13 Austritt       Ein Teilnehmer kann nur mit Saldo exakt 0 austreten.
 *
 * Bekannte Restrisiken: Wash-Trading zwischen kolludierenden Teilnehmern bläht die Umsatz-
 * Quote auf (begrenzt durch maxQuota und quotaFactor). Die Rollen ADMIN/GOVERNOR sollten in
 * Produktion Multisig- oder DAO-Timelock-Verträge sein.
 * ======================================================================
 */
contract ClearingCoin {
    // ------------------------------------------------------------------ Konstanten
    string public constant name = "ClearingCoin";
    string public constant symbol = "CLC";
    uint8 public constant decimals = 18;

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 public constant MAX_AMOUNT = 1e36;
    uint256 public constant MAX_BATCH = 200;
    uint64 public constant TIMELOCK = 2 days;

    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant GOVERNOR = keccak256("GOVERNOR");
    bytes32 public constant ADMISSION = keccak256("ADMISSION");
    bytes32 public constant CLEARING = keccak256("CLEARING");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    /// @notice Internes Konto des Gebühren-/Stabilisierungspools.
    address public constant POOL = address(uint160(uint256(keccak256("CLC.POOL"))));

    // ------------------------------------------------------------------ Typen
    struct Params {
        uint16 tier1Bps; // Schwelle 1 in Bps der Quote (z. B. 2500 = 25 %)
        uint16 tier2Bps; // Schwelle 2 (z. B. 5000 = 50 %)
        uint16 rate1Bps; // Gebühr p.a. oberhalb tier1 (z. B. 100 = 1 %)
        uint16 rate2Bps; // Gebühr p.a. oberhalb tier2 (z. B. 200 = 2 %)
        uint32 maxSurplusBps; // 0 = aus; z. B. 20000 = Guthaben max. 200 % der Quote
        uint16 quotaFactorBps; // Quote aus Umsatz (z. B. 2500 = 25 % des Umsatzes)
        uint32 turnoverWindow; // Zerfallsfenster des Umsatzes in Sekunden
        uint32 gracePeriod; // Frist bis zur Abschreibung
        uint128 maxQuota; // absolute Obergrenze jeder Quote
    }

    struct Account {
        int256 balance;
        uint128 baseQuota;
        uint128 quota;
        uint128 turnover;
        uint64 lastAccrual;
        uint64 lastTurnover;
        uint64 overdrawnSince;
        uint64 frozenSince;
        bool admitted;
        bool frozen;
        bool clearingConsent;
    }

    struct Mandate {
        uint128 maxPerTx;
        uint128 maxPerPeriod;
        uint128 spent;
        uint64 periodStart;
        uint64 expiry;
        uint32 period;
        bool restrictCounterparties;
    }

    struct Leg {
        address from;
        address to;
        uint256 amount;
        bytes32 ref;
    }

    // ------------------------------------------------------------------ State
    Params public params;
    Params public pendingParams;
    uint64 public pendingEta;

    bool public paused;
    uint256 public feesCollected;
    uint256 public lossesWrittenOff;

    mapping(address => Account) public accounts;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    mapping(address => mapping(address => Mandate)) public mandates; // principal => agent
    mapping(address => mapping(address => mapping(address => bool))) public mandateCounterparty;

    // ------------------------------------------------------------------ Events
    event Transfer(address indexed from, address indexed to, uint256 amount, bytes32 indexed ref);
    event FeeCharged(address indexed account, uint256 fee, bool onSurplus);
    event Admitted(address indexed account, uint256 baseQuota);
    event Exited(address indexed account);
    event BaseQuotaSet(address indexed account, uint256 baseQuota);
    event Frozen(address indexed account, bool frozen);
    event WrittenOff(address indexed account, uint256 loss);
    event PoolRelief(address indexed debtor, uint256 amount);
    event MandateSet(address indexed principal, address indexed agent, uint256 maxPerTx, uint256 maxPerPeriod, uint64 expiry);
    event MandateRevoked(address indexed principal, address indexed agent);
    event BatchSettled(bytes32 indexed batchId, uint256 legs);
    event ParamsProposed(uint64 eta);
    event ParamsExecuted();
    event RoleSet(bytes32 indexed role, address indexed account, bool granted);
    event Paused(bool paused);

    // ------------------------------------------------------------------ Errors
    error Unauthorized(bytes32 role);
    error InvalidParams();
    error NotAdmitted(address account);
    error AccountFrozen(address account);
    error InvalidAmount();
    error InvalidCounterparty();
    error CreditLimitExceeded(address account);
    error SurplusCapExceeded(address account);
    error IsPaused();
    error MandateInvalid();
    error MandateLimit();
    error NoClearingConsent(address account);
    error BatchSize();
    error NotEligible();
    error TimelockActive();
    error BalanceNotZero();

    // ------------------------------------------------------------------ Modifier
    modifier onlyRole(bytes32 r) {
        if (!hasRole[r][msg.sender]) revert Unauthorized(r);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    constructor(address admin, Params memory p) {
        _validate(p);
        params = p;
        bytes32[5] memory roles = [ADMIN, GOVERNOR, ADMISSION, CLEARING, GUARDIAN];
        for (uint256 i; i < roles.length; ++i) {
            hasRole[roles[i]][admin] = true;
            emit RoleSet(roles[i], admin, true);
        }
        accounts[POOL].lastAccrual = uint64(block.timestamp);
    }

    // ================================================================== Zahlungen

    /// @notice Zahlung mit Rechnungs-/Bestellreferenz.
    function transfer(address to, uint256 amount, bytes32 ref) external returns (bool) {
        _pay(msg.sender, to, amount, ref);
        return true;
    }

    /// @notice Zahlung durch einen Agenten im Rahmen seines Mandats (R9).
    function agentPay(address principal, address to, uint256 amount, bytes32 ref) external returns (bool) {
        Mandate storage m = mandates[principal][msg.sender];
        if (m.expiry == 0 || block.timestamp > m.expiry) revert MandateInvalid();
        if (amount > m.maxPerTx) revert MandateLimit();
        if (block.timestamp >= uint256(m.periodStart) + m.period) {
            m.periodStart = uint64(block.timestamp);
            m.spent = 0;
        }
        if (uint256(m.spent) + amount > m.maxPerPeriod) revert MandateLimit();
        if (m.restrictCounterparties && !mandateCounterparty[principal][msg.sender][to]) revert InvalidCounterparty();
        m.spent += uint128(amount);
        _pay(principal, to, amount, ref);
        return true;
    }

    /// @notice Multilaterales Netting durch den Clearing-Operator (R10).
    function settleBatch(Leg[] calldata legs, bytes32 batchId) external onlyRole(CLEARING) whenNotPaused {
        uint256 n = legs.length;
        if (n == 0 || n > MAX_BATCH) revert BatchSize();
        for (uint256 i; i < n; ++i) {
            if (!accounts[legs[i].from].clearingConsent) revert NoClearingConsent(legs[i].from);
            _move(legs[i].from, legs[i].to, legs[i].amount, legs[i].ref);
        }
        for (uint256 i; i < n; ++i) {
            _checkLimits(legs[i].from, legs[i].to);
        }
        for (uint256 i; i < n; ++i) {
            _bumpTurnover(legs[i].from, legs[i].amount);
            _bumpTurnover(legs[i].to, legs[i].amount);
        }
        emit BatchSettled(batchId, n);
    }

    // ================================================================== Teilnehmer

    function setClearingConsent(bool consent) external {
        if (!accounts[msg.sender].admitted) revert NotAdmitted(msg.sender);
        accounts[msg.sender].clearingConsent = consent;
    }

    function setMandate(address agent, uint128 maxPerTx, uint128 maxPerPeriod, uint32 period, uint64 expiry, bool restrictCounterparties)
        external
    {
        if (!accounts[msg.sender].admitted) revert NotAdmitted(msg.sender);
        if (agent == address(0) || agent == msg.sender || period == 0 || expiry <= block.timestamp || maxPerTx > maxPerPeriod) {
            revert MandateInvalid();
        }
        mandates[msg.sender][agent] = Mandate({
            maxPerTx: maxPerTx,
            maxPerPeriod: maxPerPeriod,
            spent: 0,
            periodStart: uint64(block.timestamp),
            expiry: expiry,
            period: period,
            restrictCounterparties: restrictCounterparties
        });
        emit MandateSet(msg.sender, agent, maxPerTx, maxPerPeriod, expiry);
    }

    function setMandateCounterparty(address agent, address counterparty, bool allowed) external {
        mandateCounterparty[msg.sender][agent][counterparty] = allowed;
    }

    function revokeMandate(address agent) external {
        delete mandates[msg.sender][agent];
        emit MandateRevoked(msg.sender, agent);
    }

    /// @notice Austritt nur mit Saldo 0 (R13).
    function exit() external {
        Account storage a = accounts[msg.sender];
        if (!a.admitted) revert NotAdmitted(msg.sender);
        if (a.frozen) revert AccountFrozen(msg.sender);
        _accrue(msg.sender);
        if (a.balance != 0) revert BalanceNotZero();
        delete accounts[msg.sender];
        emit Exited(msg.sender);
    }

    /// @notice Gebühren abrechnen und Quote aktualisieren. Für jeden aufrufbar (R4).
    function poke(address account) external {
        if (!accounts[account].admitted) revert NotAdmitted(account);
        _accrue(account);
        _bumpTurnover(account, 0);
        _updateOverdraft(account);
    }

    // ================================================================== Zulassung / Governance

    function admit(address account, uint128 baseQuota) external onlyRole(ADMISSION) {
        Account storage a = accounts[account];
        if (account == address(0) || account == POOL || a.admitted) revert InvalidCounterparty();
        if (baseQuota == 0 || baseQuota > params.maxQuota) revert InvalidParams();
        a.admitted = true;
        a.baseQuota = baseQuota;
        a.quota = baseQuota;
        a.lastAccrual = uint64(block.timestamp);
        a.lastTurnover = uint64(block.timestamp);
        emit Admitted(account, baseQuota);
    }

    function setBaseQuota(address account, uint128 baseQuota) external onlyRole(ADMISSION) {
        Account storage a = accounts[account];
        if (!a.admitted) revert NotAdmitted(account);
        if (baseQuota == 0 || baseQuota > params.maxQuota) revert InvalidParams();
        _accrue(account);
        a.baseQuota = baseQuota;
        _recalcQuota(a);
        _updateOverdraft(account);
        emit BaseQuotaSet(account, baseQuota);
    }

    function setFrozen(address account, bool frozen_) external onlyRole(GOVERNOR) {
        Account storage a = accounts[account];
        if (!a.admitted) revert NotAdmitted(account);
        _accrue(account);
        a.frozen = frozen_;
        a.frozenSince = frozen_ ? uint64(block.timestamp) : 0;
        emit Frozen(account, frozen_);
    }

    /// @notice Abschreibung einer ausgefallenen Schuld, Verlust trägt der Pool (R7).
    function writeOff(address account) external onlyRole(GOVERNOR) {
        Account storage a = accounts[account];
        if (!a.admitted) revert NotAdmitted(account);
        _accrue(account);
        _updateOverdraft(account);
        if (a.balance >= 0) revert NotEligible();
        uint256 g = params.gracePeriod;
        bool overdue = a.overdrawnSince != 0 && block.timestamp >= uint256(a.overdrawnSince) + g;
        bool frozenLong = a.frozen && block.timestamp >= uint256(a.frozenSince) + g;
        if (!overdue && !frozenLong) revert NotEligible();

        int256 loss = a.balance;
        a.balance = 0;
        a.overdrawnSince = 0;
        if (!a.frozen) {
            a.frozen = true;
            a.frozenSince = uint64(block.timestamp);
        }
        accounts[POOL].balance += loss;
        lossesWrittenOff += uint256(-loss);
        emit WrittenOff(account, uint256(-loss));
    }

    /// @notice Pool-Mittel nur zum Schuldenabbau, nie zur Guthabenbildung (R8).
    function poolRelief(address debtor, uint256 amount) external onlyRole(GOVERNOR) {
        Account storage d = accounts[debtor];
        if (!d.admitted) revert NotAdmitted(debtor);
        if (d.frozen) revert AccountFrozen(debtor);
        if (amount == 0 || amount > MAX_AMOUNT) revert InvalidAmount();
        _accrue(debtor);
        Account storage p = accounts[POOL];
        if (d.balance + int256(amount) > 0 || p.balance < int256(amount)) revert NotEligible();
        p.balance -= int256(amount);
        d.balance += int256(amount);
        _updateOverdraft(debtor);
        emit PoolRelief(debtor, amount);
    }

    function proposeParams(Params calldata p) external onlyRole(GOVERNOR) {
        _validate(p);
        pendingParams = p;
        pendingEta = uint64(block.timestamp) + TIMELOCK;
        emit ParamsProposed(pendingEta);
    }

    function executeParams() external onlyRole(GOVERNOR) {
        if (pendingEta == 0 || block.timestamp < pendingEta) revert TimelockActive();
        params = pendingParams;
        pendingEta = 0;
        emit ParamsExecuted();
    }

    function cancelParams() external onlyRole(GOVERNOR) {
        pendingEta = 0;
    }

    function grantRole(bytes32 role, address account) external onlyRole(ADMIN) {
        hasRole[role][account] = true;
        emit RoleSet(role, account, true);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN) {
        hasRole[role][account] = false;
        emit RoleSet(role, account, false);
    }

    function pause() external onlyRole(GUARDIAN) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GOVERNOR) {
        paused = false;
        emit Paused(false);
    }

    // ================================================================== Views

    /// @notice Saldo inklusive noch nicht abgerechneter Gebühren.
    function balanceOf(address account) external view returns (int256) {
        Account storage a = accounts[account];
        if (account == POOL || a.frozen) return a.balance;
        return a.balance - int256(pendingFee(account));
    }

    function pendingFee(address account) public view returns (uint256) {
        Account storage a = accounts[account];
        if (account == POOL || a.frozen || !a.admitted) return 0;
        return _fee(_abs(a.balance), a.quota, _elapsed(a.lastAccrual));
    }

    /// @notice Noch verfügbarer Ausgaberahmen (Guthaben + Kreditlinie), ohne ausstehende Gebühren.
    function availableToSpend(address account) external view returns (uint256) {
        Account storage a = accounts[account];
        if (!a.admitted || a.frozen) return 0;
        int256 room = a.balance - int256(pendingFee(account)) + int256(uint256(a.quota));
        return room > 0 ? uint256(room) : 0;
    }

    function poolBalance() external view returns (int256) {
        return accounts[POOL].balance;
    }

    // ================================================================== Intern

    function _pay(address from, address to, uint256 amount, bytes32 ref) internal whenNotPaused {
        _move(from, to, amount, ref);
        _checkLimits(from, to);
        _bumpTurnover(from, amount);
        _bumpTurnover(to, amount);
    }

    function _move(address from, address to, uint256 amount, bytes32 ref) internal {
        if (amount == 0 || amount > MAX_AMOUNT) revert InvalidAmount();
        if (from == to) revert InvalidCounterparty();
        Account storage f = accounts[from];
        Account storage t = accounts[to];
        if (!f.admitted) revert NotAdmitted(from);
        if (!t.admitted) revert NotAdmitted(to);
        if (f.frozen) revert AccountFrozen(from);
        if (t.frozen) revert AccountFrozen(to);
        _accrue(from);
        _accrue(to);
        f.balance -= int256(amount);
        t.balance += int256(amount);
        emit Transfer(from, to, amount, ref);
    }

    function _checkLimits(address from, address to) internal {
        Account storage f = accounts[from];
        if (f.balance < -int256(uint256(f.quota))) revert CreditLimitExceeded(from);
        uint256 cap = params.maxSurplusBps;
        if (cap != 0) {
            Account storage t = accounts[to];
            if (t.balance > int256(uint256(t.quota) * cap / BPS)) revert SurplusCapExceeded(to);
        }
        _updateOverdraft(from);
        _updateOverdraft(to);
    }

    function _accrue(address account) internal {
        Account storage a = accounts[account];
        uint256 dt = _elapsed(a.lastAccrual);
        if (dt == 0) return;
        a.lastAccrual = uint64(block.timestamp);
        if (account == POOL || a.frozen) return;

        uint256 fee = _fee(_abs(a.balance), a.quota, dt);
        if (fee == 0) return;
        bool onSurplus = a.balance > 0;
        a.balance -= int256(fee);
        accounts[POOL].balance += int256(fee);
        feesCollected += fee;
        emit FeeCharged(account, fee, onSurplus);
    }

    function _fee(uint256 absBal, uint256 quota, uint256 dt) internal view returns (uint256 fee) {
        Params storage p = params;
        uint256 t1 = quota * p.tier1Bps / BPS;
        if (absBal <= t1 || dt == 0) return 0;
        uint256 t2 = quota * p.tier2Bps / BPS;
        uint256 band1 = (absBal > t2 ? t2 : absBal) - t1;
        fee = band1 * p.rate1Bps * dt / (BPS * YEAR);
        if (absBal > t2) fee += (absBal - t2) * p.rate2Bps * dt / (BPS * YEAR);
        uint256 maxFee = absBal - t1; // nie unter tier1 in einer Abrechnung
        if (fee > maxFee) fee = maxFee;
    }

    function _bumpTurnover(address account, uint256 amount) internal {
        Account storage a = accounts[account];
        uint256 w = params.turnoverWindow;
        uint256 dt = _elapsed(a.lastTurnover);
        uint256 t = dt >= w ? 0 : uint256(a.turnover) * (w - dt) / w;
        t += amount;
        if (t > type(uint128).max) t = type(uint128).max;
        a.turnover = uint128(t);
        a.lastTurnover = uint64(block.timestamp);
        _recalcQuota(a);
    }

    function _recalcQuota(Account storage a) internal {
        uint256 q = uint256(a.turnover) * params.quotaFactorBps / BPS;
        if (q < a.baseQuota) q = a.baseQuota;
        if (q > params.maxQuota) q = params.maxQuota;
        a.quota = uint128(q);
    }

    function _updateOverdraft(address account) internal {
        Account storage a = accounts[account];
        if (a.balance < -int256(uint256(a.quota))) {
            if (a.overdrawnSince == 0) a.overdrawnSince = uint64(block.timestamp);
        } else {
            a.overdrawnSince = 0;
        }
    }

    function _validate(Params memory p) internal pure {
        if (
            p.tier1Bps == 0 || p.tier1Bps >= p.tier2Bps || p.tier2Bps > 20_000 || p.rate1Bps > 500 || p.rate2Bps > 1_000
                || p.rate1Bps > p.rate2Bps || (p.maxSurplusBps != 0 && p.maxSurplusBps < p.tier2Bps) || p.quotaFactorBps > 5_000
                || p.turnoverWindow < 30 days || p.turnoverWindow > 730 days || p.gracePeriod < 7 days || p.maxQuota == 0
                || p.maxQuota > MAX_AMOUNT
        ) revert InvalidParams();
    }

    function _elapsed(uint64 since) internal view returns (uint256) {
        return block.timestamp > since ? block.timestamp - since : 0;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
