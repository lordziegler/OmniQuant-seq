#!/usr/bin/env bash
# Interactive entry menu, shown by run.sh and setup.sh when they are called
# with no arguments (or with --interactive).
#
# The menu owns no pipeline logic: every option re-enters one of the two entry
# points with the flag that already implements it, so the scriptable CLI and
# the menu can never drift apart.

# Run one entry point and come back to the menu, reporting a failure instead of
# aborting the whole session (set -e would otherwise kill the menu).
menu_dispatch() {
    local status=0
    echo ""
    bash "$@" || status=$?
    (( status == 0 )) || echo "[WARN] '${*##*/}' exited with status ${status} — see the messages above."
    echo ""
}

menu_show() {
    cat <<EOF

============================================================
 OmniQuant-seq — RNA-seq expression pipeline

 Select an option:
   [1] Configure pipeline resources
   [2] Configure analysis parameters
   [3] Configure species (interactive)
   [4] Build references
   [5] Run test mode
   [6] Run example (${EXAMPLE_SPECIES})
   [7] Run full production
   [8] Exit
============================================================
EOF
}

menu_main() {
    local choice
    while true; do
        menu_show
        # A closed stdin (piped or redirected input) ends the menu instead of
        # spinning forever on EOF.
        read -rp " Option [1-8]: " choice || { echo ""; return 0; }
        case "$choice" in
            1) menu_dispatch "${PIPELINE_DIR}/setup.sh" --resources ;;
            2) menu_dispatch "${PIPELINE_DIR}/setup.sh" --analysis ;;
            3) menu_dispatch "${PIPELINE_DIR}/setup.sh" --species ;;
            4) menu_dispatch "${PIPELINE_DIR}/run.sh"   --build-refs ;;
            5) menu_dispatch "${PIPELINE_DIR}/run.sh"   --test ;;
            6) menu_dispatch "${PIPELINE_DIR}/run.sh"   --example ;;
            7) menu_dispatch "${PIPELINE_DIR}/run.sh"   --full ;;
            8|q|Q|quit|exit) echo " Bye."; return 0 ;;
            "") ;;   # bare Enter simply redraws the menu
            *) echo " '${choice}' is not a valid option — enter a number between 1 and 8." ;;
        esac
    done
}
