------------------------ MODULE AppUpdaterStateMachine ------------------------
(*
 * Formal TLA+ specification of Reader's self-updater security, policy,
 * artifact verification, and staged-on-quit / install-now bundle swap with
 * automatic rollback.
 *
 * True-to-code mapping (commit 82f73bd9864eb93dfe58d50a33ed68d74e647a1a):
 *   - Packages/ReaderCore/Sources/ReaderCore/Updater.swift:
 *       AppBuildInfo, UpdateEvaluator.parseManifest, UpdateEvaluator.evaluate,
 *       UpdateSwapScript.build
 *   - App/Reader/Updater/AppUpdater.swift:
 *       AppUpdater.checkForUpdates, AppUpdater.verifySignature,
 *       AppUpdater.stageUpdateInBackground, AppUpdater.downloadAndStage,
 *       AppUpdater.sha256Hex, AppUpdater.validateAppBundle,
 *       AppUpdater.installUpdate, AppUpdater.applyStagedUpdateOnQuitIfNeeded,
 *       AppUpdater.launchSwap
 *
 * Key guarantees checked:
 *   - NoUnverifiedInstall: No candidate app can be staged as ready or swapped
 *     into TARGET without passing Ed25519 signature verification, manifest
 *     policy checks (schema=1, channel="main", trusted HTTPS URL prefix),
 *     SHA-256 digest match, and app bundle/codesign validation.
 *   - NoSilentDowngrade: Production builds never accept a lower buildNumber or
 *     identical (buildNumber, commitSHA); dev builds never upgrade silently on
 *     background checks (manual check required).
 *   - RollbackPreservesRunnableApp: At every intermediate swap step a runnable
 *     bundle exists at TARGET or BACKUP; if mv/ditto or `open -n` fails,
 *     `restore_backup` restores TARGET to the prior valid app and cleans BACKUP.
 *   - StagedSwapTerminatesCleanly (liveness): Once a staged swap script spawns,
 *     it always terminates cleanly in either `done_installed` or `done_rolled_back`.
 *)

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    BUILDS,          \* Candidate build numbers (e.g. {1, 2, 3} with INIT_BUILD = 2)
    INIT_BUILD,      \* Installed app's buildNumber
    COMMITS,         \* Abstract commit SHAs (e.g. {"c1", "c2"})
    INIT_COMMIT,     \* Installed app's commitSHA
    CHANNELS,        \* Manifest channels (e.g. {"main", "beta"})
    SCHEMAS,         \* Manifest schema versions (e.g. {1, 2})
    BUG_MODE         \* "none" | "skip_rollback_on_swap_fail" | "skip_sha_check"
                     \* | "skip_sig_check" | "allow_downgrade"

PHASES == {
    "idle",
    "fetched",
    "sig_verified",
    "available",
    "downloaded",
    "ready_to_install",
    "swap_wait_exit",
    "swap_moved_to_backup",
    "swap_copied_staged",
    "done_installed",
    "done_rolled_back",
    "done_up_to_date",
    "done_error"
}

TERMINAL_PHASES == {"done_installed", "done_rolled_back", "done_up_to_date", "done_error"}

VARIABLES
    \* Currently installed app & filesystem slots (TARGET, BACKUP, STAGED)
    currentBuild,
    currentCommit,
    currentIsDev,
    targetState,       \* "valid_old" | "valid_new" | "missing" | "corrupt"
    backupState,       \* "absent" | "valid_old"
    stagedState,       \* "absent" | "unverified" | "verified"
    appRunning,        \* "old" | "new" | "stopped"

    \* Updater state machine & swap script phase
    phase,
    manualCheck,
    launchUpdated,
    swapSpawned,

    \* Candidate manifest & downloaded artifact attributes (adversarial environment)
    candSchema,
    candChannel,
    candBuild,
    candCommit,
    candUrlTrusted,
    candSigValid,
    candShaMatches,
    candBundleValid,

    \* Verification audit state
    sigChecked,
    policyChecked,
    shaChecked,
    bundleChecked

fsVars == <<currentBuild, currentCommit, currentIsDev, targetState, backupState, stagedState, appRunning>>
ctrlVars == <<phase, manualCheck, launchUpdated, swapSpawned>>
candVars == <<candSchema, candChannel, candBuild, candCommit, candUrlTrusted, candSigValid, candShaMatches, candBundleValid>>
auditVars == <<sigChecked, policyChecked, shaChecked, bundleChecked>>
vars == <<fsVars, ctrlVars, candVars, auditVars>>

-----------------------------------------------------------------------------
\* Policy helper matching UpdateEvaluator.evaluate (Updater.swift:242-251)
PolicyAllowsUpgrade ==
    IF currentIsDev THEN
        manualCheck
    ELSE
        \/ candBuild > currentBuild
        \/ (candBuild = currentBuild /\ candCommit # currentCommit)

-----------------------------------------------------------------------------
Init ==
    /\ currentBuild = INIT_BUILD
    /\ currentCommit = INIT_COMMIT
    /\ currentIsDev \in BOOLEAN
    /\ targetState = "valid_old"
    /\ backupState = "absent"
    /\ stagedState = "absent"
    /\ appRunning = "old"

    /\ phase = "idle"
    /\ manualCheck = FALSE
    /\ launchUpdated = FALSE
    /\ swapSpawned = FALSE

    /\ candSchema = 1
    /\ candChannel = "main"
    /\ candBuild = INIT_BUILD
    /\ candCommit = INIT_COMMIT
    /\ candUrlTrusted = TRUE
    /\ candSigValid = FALSE
    /\ candShaMatches = FALSE
    /\ candBundleValid = FALSE

    /\ sigChecked = FALSE
    /\ policyChecked = FALSE
    /\ shaChecked = FALSE
    /\ bundleChecked = FALSE

-----------------------------------------------------------------------------
\* Step 1: Fetch manifest.json + manifest.json.sig (AppUpdater.checkForUpdates)
FetchManifest(manual, schema, channel, build, commit, urlTrusted, sigValid) ==
    /\ phase = "idle"
    /\ manualCheck' = manual
    /\ candSchema' = schema
    /\ candChannel' = channel
    /\ candBuild' = build
    /\ candCommit' = commit
    /\ candUrlTrusted' = urlTrusted
    /\ candSigValid' = sigValid
    /\ phase' = "fetched"
    /\ UNCHANGED <<fsVars, launchUpdated, swapSpawned, candShaMatches, candBundleValid, auditVars>>

\* Step 2: Ed25519 signature verification BEFORE JSON parsing (AppUpdater.verifySignature)
VerifyManifestSignature ==
    /\ phase = "fetched"
    /\ IF candSigValid \/ BUG_MODE = "skip_sig_check" THEN
           /\ sigChecked' = candSigValid
           /\ phase' = "sig_verified"
       ELSE
           /\ UNCHANGED sigChecked
           /\ phase' = "done_error"
    /\ UNCHANGED <<fsVars, manualCheck, launchUpdated, swapSpawned, candVars,
                   policyChecked, shaChecked, bundleChecked>>

\* Step 3: Schema, channel, trusted URL prefix, and anti-downgrade policy check
\* Maps to UpdateEvaluator.parseManifest + UpdateEvaluator.evaluate (Updater.swift:195-252)
EvaluatePolicy ==
    /\ phase = "sig_verified"
    /\ IF candSchema # 1 \/ candChannel # "main" \/ ~candUrlTrusted THEN
           /\ phase' = "done_error"
           /\ UNCHANGED policyChecked
       ELSE IF PolicyAllowsUpgrade \/ BUG_MODE = "allow_downgrade" THEN
           /\ policyChecked' = (candSchema = 1 /\ candChannel = "main" /\ candUrlTrusted /\ PolicyAllowsUpgrade)
           /\ phase' = "available"
       ELSE
           /\ phase' = "done_up_to_date"
           /\ UNCHANGED policyChecked
    /\ UNCHANGED <<fsVars, manualCheck, launchUpdated, swapSpawned, candVars,
                   sigChecked, shaChecked, bundleChecked>>

\* Step 4: Download archive to cache staging directory (AppUpdater.downloadAndStage)
DownloadArtifact(shaMatches, bundleValid) ==
    /\ phase = "available"
    /\ stagedState' = "unverified"
    /\ candShaMatches' = shaMatches
    /\ candBundleValid' = bundleValid
    /\ phase' = "downloaded"
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev, targetState, backupState, appRunning,
                   manualCheck, launchUpdated, swapSpawned,
                   candSchema, candChannel, candBuild, candCommit, candUrlTrusted, candSigValid,
                   auditVars>>

\* Step 5: Verify SHA-256 digest, extract zip, validate Info.plist + bundleID + codesign
\* Maps to AppUpdater.downloadAndStage + sha256Hex + validateAppBundle (AppUpdater.swift:547-560)
VerifyDownloadAndStage ==
    /\ phase = "downloaded"
    /\ IF (candShaMatches \/ BUG_MODE = "skip_sha_check") /\ candBundleValid THEN
           /\ shaChecked' = candShaMatches
           /\ bundleChecked' = candBundleValid
           /\ stagedState' = "verified"
           /\ phase' = "ready_to_install"
       ELSE
           /\ UNCHANGED <<shaChecked, bundleChecked>>
           /\ stagedState' = "absent"
           /\ phase' = "done_error"
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev, targetState, backupState, appRunning,
                   manualCheck, launchUpdated, swapSpawned, candVars, sigChecked, policyChecked>>

\* Optional: User skips release before installing (AppUpdater.skipRelease)
UserSkipRelease ==
    /\ phase \in {"available", "ready_to_install"}
    /\ stagedState' = "absent"
    /\ phase' = "done_up_to_date"
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev, targetState, backupState, appRunning,
                   manualCheck, launchUpdated, swapSpawned, candVars, auditVars>>

\* Step 6: Spawn detached swap script (at most once via hasSpawnedSwapScript)
\* launch = TRUE  -> installUpdate / launchSwap ("swap-and-relaunch.sh")
\* launch = FALSE -> applyStagedUpdateOnQuitIfNeeded ("swap-on-quit.sh")
SpawnSwapScript(launch) ==
    /\ phase = "ready_to_install"
    /\ ~swapSpawned
    /\ stagedState = "verified"
    /\ swapSpawned' = TRUE
    /\ launchUpdated' = launch
    /\ appRunning' = "stopped"
    /\ phase' = "swap_wait_exit"
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev, targetState, backupState, stagedState,
                   manualCheck, candVars, auditVars>>

\* Step 7: Swap script moves TARGET -> BACKUP (`rm -rf "$BACKUP"; mv "$TARGET" "$BACKUP"`)
\* Maps to UpdateSwapScript.build (Updater.swift:298-301)
SwapMoveTargetToBackup(moveSucceeds) ==
    /\ phase = "swap_wait_exit"
    /\ IF moveSucceeds THEN
           /\ backupState' = "valid_old"
           /\ targetState' = "missing"
           /\ phase' = "swap_moved_to_backup"
           /\ UNCHANGED appRunning
       ELSE
           \* `mv "$TARGET" "$BACKUP"` failed under `set -e` before TARGET moved:
           \* TARGET is still intact as valid_old!
           /\ targetState' = "valid_old"
           /\ backupState' = "absent"
           /\ phase' = "done_rolled_back"
           /\ UNCHANGED appRunning
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev, stagedState,
                   manualCheck, launchUpdated, swapSpawned, candVars, auditVars>>

\* Step 8: Swap script places STAGED -> TARGET (`mv` or `ditto`); on failure runs `restore_backup`
\* Maps to UpdateSwapScript.build (Updater.swift:303-310)
SwapPlaceStaged(placeSucceeds) ==
    /\ phase = "swap_moved_to_backup"
    /\ IF placeSucceeds THEN
           /\ targetState' = "valid_new"
           /\ stagedState' = "absent"
           /\ phase' = "swap_copied_staged"
           /\ UNCHANGED <<backupState, appRunning>>
       ELSE
           \* Both `mv` and `ditto` failed -> `rm -rf "$TARGET"; restore_backup; exit 1`
           IF BUG_MODE = "skip_rollback_on_swap_fail" THEN
               /\ targetState' = "corrupt"
               /\ phase' = "done_rolled_back"
               /\ UNCHANGED <<backupState, stagedState, appRunning>>
           ELSE
               /\ targetState' = "valid_old"
               /\ backupState' = "absent"
               /\ stagedState' = "absent"
               /\ appRunning' = IF launchUpdated THEN "old" ELSE "stopped"
               /\ phase' = "done_rolled_back"
    /\ UNCHANGED <<currentBuild, currentCommit, currentIsDev,
                   manualCheck, launchUpdated, swapSpawned, candVars, auditVars>>

\* Step 9: Swap script launches updated app (if LAUNCH=1) and cleans BACKUP;
\* if `open -n "$TARGET"` fails, runs `rm -rf "$TARGET"; restore_backup; exit 1`.
\* Maps to UpdateSwapScript.build (Updater.swift:312-319)
SwapLaunchAndCleanup(launchSucceeds) ==
    /\ phase = "swap_copied_staged"
    /\ (~launchUpdated => launchSucceeds)  \* No launch attempted when LAUNCH=0
    /\ IF launchSucceeds THEN
           /\ backupState' = "absent"
           /\ appRunning' = IF launchUpdated THEN "new" ELSE "stopped"
           /\ currentBuild' = candBuild
           /\ currentCommit' = candCommit
           /\ phase' = "done_installed"
           /\ UNCHANGED targetState
       ELSE
           \* `open -n "$TARGET"` failed -> `rm -rf "$TARGET"; restore_backup; exit 1`
           IF BUG_MODE = "skip_rollback_on_swap_fail" THEN
               /\ targetState' = "missing"
               /\ phase' = "done_rolled_back"
               /\ UNCHANGED <<currentBuild, currentCommit, backupState, appRunning>>
           ELSE
               /\ targetState' = "valid_old"
               /\ backupState' = "absent"
               /\ appRunning' = "old"
               /\ phase' = "done_rolled_back"
               /\ UNCHANGED <<currentBuild, currentCommit>>
    /\ UNCHANGED <<currentIsDev, stagedState, manualCheck, launchUpdated, swapSpawned, candVars, auditVars>>

\* Terminal step ONLY in terminal phases (deadlock checking catches any mid-protocol stall!)
Done ==
    /\ phase \in TERMINAL_PHASES
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
Next ==
    \/ \E m \in BOOLEAN, s \in SCHEMAS, ch \in CHANNELS, b \in BUILDS,
          cm \in COMMITS, u \in BOOLEAN, sig \in BOOLEAN :
          FetchManifest(m, s, ch, b, cm, u, sig)
    \/ VerifyManifestSignature
    \/ EvaluatePolicy
    \/ \E sha \in BOOLEAN, bv \in BOOLEAN : DownloadArtifact(sha, bv)
    \/ VerifyDownloadAndStage
    \/ UserSkipRelease
    \/ \E launch \in BOOLEAN : SpawnSwapScript(launch)
    \/ \E ok \in BOOLEAN : SwapMoveTargetToBackup(ok)
    \/ \E ok \in BOOLEAN : SwapPlaceStaged(ok)
    \/ \E ok \in BOOLEAN : SwapLaunchAndCleanup(ok)
    \/ Done

Fairness ==
    /\ WF_vars(VerifyManifestSignature)
    /\ WF_vars(EvaluatePolicy)
    /\ WF_vars(VerifyDownloadAndStage)
    /\ WF_vars(\E ok \in BOOLEAN : SwapMoveTargetToBackup(ok))
    /\ WF_vars(\E ok \in BOOLEAN : SwapPlaceStaged(ok))
    /\ WF_vars(\E ok \in BOOLEAN : SwapLaunchAndCleanup(ok))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Safety invariants

TypeOK ==
    /\ currentBuild \in BUILDS
    /\ currentCommit \in COMMITS
    /\ currentIsDev \in BOOLEAN
    /\ targetState \in {"valid_old", "valid_new", "missing", "corrupt"}
    /\ backupState \in {"absent", "valid_old"}
    /\ stagedState \in {"absent", "unverified", "verified"}
    /\ appRunning \in {"old", "new", "stopped"}
    /\ phase \in PHASES
    /\ manualCheck \in BOOLEAN
    /\ launchUpdated \in BOOLEAN
    /\ swapSpawned \in BOOLEAN
    /\ candSchema \in SCHEMAS
    /\ candChannel \in CHANNELS
    /\ candBuild \in BUILDS
    /\ candCommit \in COMMITS
    /\ candUrlTrusted \in BOOLEAN
    /\ candSigValid \in BOOLEAN
    /\ candShaMatches \in BOOLEAN
    /\ candBundleValid \in BOOLEAN
    /\ sigChecked \in BOOLEAN
    /\ policyChecked \in BOOLEAN
    /\ shaChecked \in BOOLEAN
    /\ bundleChecked \in BOOLEAN

\* No update can reach ready_to_install, swap, or TARGET without passing ALL checks:
\* Ed25519 signature, schema/channel/URL policy, SHA-256 checksum, and bundle/codesign validation.
NoUnverifiedInstall ==
    (phase \in {"ready_to_install", "swap_wait_exit", "swap_moved_to_backup",
                "swap_copied_staged", "done_installed"}
     \/ targetState = "valid_new")
    => (sigChecked /\ policyChecked /\ shaChecked /\ bundleChecked
        /\ candSigValid /\ candShaMatches /\ candBundleValid
        /\ candSchema = 1 /\ candChannel = "main" /\ candUrlTrusted)

\* Production builds never downgrade (candBuild < INIT_BUILD) or reinstall identical (build, commit);
\* dev builds never silently upgrade on background checks (manualCheck = FALSE).
NoSilentDowngrade ==
    phase \in {"available", "downloaded", "ready_to_install", "swap_wait_exit",
               "swap_moved_to_backup", "swap_copied_staged", "done_installed"}
    => (IF currentIsDev THEN
            manualCheck
        ELSE
            (candBuild > INIT_BUILD \/ (candBuild = INIT_BUILD /\ candCommit # INIT_COMMIT)))

\* At every swap step a valid runnable bundle exists in TARGET or BACKUP;
\* rollback always restores valid_old at TARGET and cleans BACKUP;
\* successful install always leaves valid_new at TARGET and cleans BACKUP.
RollbackPreservesRunnableApp ==
    /\ (phase \in {"swap_moved_to_backup", "swap_copied_staged"}
        => (targetState \in {"valid_old", "valid_new"} \/ backupState = "valid_old"))
    /\ (phase = "done_rolled_back"
        => (targetState = "valid_old" /\ backupState = "absent"))
    /\ (phase = "done_installed"
        => (targetState = "valid_new" /\ backupState = "absent"))
    /\ (phase \in {"idle", "fetched", "sig_verified", "available", "downloaded",
                   "ready_to_install", "swap_wait_exit", "done_up_to_date", "done_error"}
        => targetState = "valid_old")

-----------------------------------------------------------------------------
\* Temporal liveness: once a staged swap script is spawned, it always terminates cleanly

StagedSwapTerminatesCleanly ==
    (phase = "swap_wait_exit") ~> (phase \in {"done_installed", "done_rolled_back"})

=============================================================================
