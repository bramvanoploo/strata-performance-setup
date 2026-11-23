#!/usr/bin/env bash
# PLUGIN_ID: example
# PLUGIN_NAME: Example Host
# PLUGIN_DESC: Install, configure, and manage Example LLM server

# Register this host plugin with the core wizard.
register_host_plugin \
  --id "example" \
  --name "Example Host" \
  --description "Install, configure, and manage Example LLM server"

# Called once immediately after this plugin is sourced.
# Use this to detect binaries/containers or start lightweight background pollers.
example_init() {
  :
}

# Print a single formatted row for the Index page.
# Argument $1: "true" if currently selected by the cursor, "false" otherwise.
example_menu_row() {
  local selected="${1:-false}"
  local prefix="  "
  [[ "$selected" == true ]] && prefix="▶ "
  if [[ "$selected" == true ]]; then
    printf "%b%s[EXAMPLE]  Example Host (ready)%b" "${C_BOLD}${C_CYAN}" "$prefix" "$C_RESET"
  else
    printf "%s%b[EXAMPLE]%b  %bExample Host (ready)%b" "$prefix" "${C_MAGENTA}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  fi
}

# Called when the user presses Enter on this host plugin row.
# Should render an interactive subpage and return 0 when the user goes back.
example_open() {
  print_header
  echo -e "${C_BOLD}Example Host Manager${C_RESET}"
  echo ""
  echo "  Add install, update, service, and benchmark options here."
  echo "  Reuse core helpers: run_root, install_service, service_ctl, pkg_install, confirm_yn"
  pause_prompt
}

# --- Optional hooks (uncomment if needed) ---

# Append live status lines to LIVE_STAT_LINES / LIVE_COMPACT_STRATA on [STATS] view:
# example_live_stats() { :; }

# Print summary lines during `--check` / [c] Check Summary:
# example_check_summary() { echo "  Example:  not installed"; }

# Print hardware/compatibility warnings on the Inference Servers page:
# example_hw_warnings() { :; }

# Stop any background pollers started by example_init:
# example_cleanup() { :; }
