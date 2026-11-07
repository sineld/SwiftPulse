import Testing

/// Suites that swap process-wide test hooks (`KeychainService.overrideStoreURL`, `SyncVault.defaults`) and reset them
/// when they finish. Running in parallel, one suite's reset can land in the middle of another suite's test, so the
/// suites nested here run one at a time; everything else still runs in parallel.
@Suite(.serialized) enum SharedStateTests {}
