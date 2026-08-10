#!/bin/bash
# ==============================================================================
# Custom OCF Resource Agent - oci-vip
# Provider: jobbridge
# Installed at: /usr/lib/ocf/resource.d/jobbridge/oci-vip (both cluster nodes)
# Project / Cluster: jobbridge-ha
#
# Purpose:
#   Coordinates a floating VIP that must exist simultaneously at two levels:
#     1. The OCI VNIC fabric (as a secondary private IP)
#     2. The local Linux network interface (via `ip addr`)
#   Standard ocf:heartbeat:IPaddr2 only manages level 2, which is insufficient
#   in OCI, since the network fabric will not route to an address the VNIC
#   does not recognize. See docs/05-pacemaker-corosync-vip.md for context.
#
# Authentication:
#   Uses OCI Instance Principal (no embedded API keys). Requires the executing
#   instance to be a member of a Dynamic Group with `use private-ips`,
#   `use vnics`, and `use subnets` permissions in the target tenancy/compartment.
# ==============================================================================

. /usr/lib/ocf/lib/heartbeat/ocf-shellfuncs

VIP="${OCF_RESKEY_vip:-10.0.1.100}"
PREFIX="${OCF_RESKEY_prefix:-24}"
IFACE="${OCF_RESKEY_interface:-ens3}"
OCI="${OCF_RESKEY_oci_path:-/home/ubuntu/bin/oci}"

NODE1_NAME="${OCF_RESKEY_node1_name:-vnic-node1}"
NODE2_NAME="${OCF_RESKEY_node2_name:-vnic-node2}"
VNIC_NODE1="${OCF_RESKEY_vnic_node1:-}"
VNIC_NODE2="${OCF_RESKEY_vnic_node2:-}"
CURRENT_NODE="${OCF_RESKEY_CRM_meta_on_node:-$(hostname -s)}"

get_local_vnic() {
  case "$CURRENT_NODE" in
    "$NODE1_NAME") echo "$VNIC_NODE1" ;;
    "$NODE2_NAME") echo "$VNIC_NODE2" ;;
    *) return 1 ;;
  esac
}

local_has_vip() {
  ip -4 addr show dev "$IFACE" | grep -q "$VIP/$PREFIX"
}

oci_has_vip() {
  local vnic
  vnic="$(get_local_vnic)" || return 1
  "$OCI" network private-ip list \
    --vnic-id "$vnic" \
    --auth instance_principal \
    --output json 2>/dev/null | \
    grep -q "\"ip-address\": \"$VIP\""
}

vip_validate() {
  [ -x "$OCI" ] || return $OCF_ERR_INSTALLED
  ip link show "$IFACE" >/dev/null 2>&1 || return $OCF_ERR_CONFIGURED
  [ -n "$VNIC_NODE1" ] || return $OCF_ERR_CONFIGURED
  [ -n "$VNIC_NODE2" ] || return $OCF_ERR_CONFIGURED
  get_local_vnic >/dev/null || return $OCF_ERR_CONFIGURED
  return $OCF_SUCCESS
}

vip_start() {
  vip_validate || return $?
  local vnic
  vnic="$(get_local_vnic)" || return $OCF_ERR_CONFIGURED

  if ! oci_has_vip; then
    "$OCI" network vnic assign-private-ip \
      --vnic-id "$vnic" \
      --ip-address "$VIP" \
      --unassign-if-already-assigned \
      --auth instance_principal >/dev/null 2>&1 || return $OCF_ERR_GENERIC

    for i in $(seq 1 15); do
      oci_has_vip && break
      sleep 1
    done
    oci_has_vip || return $OCF_ERR_GENERIC
  fi

  if ! local_has_vip; then
    ip addr add "$VIP/$PREFIX" dev "$IFACE" label "$IFACE:1" || return $OCF_ERR_GENERIC
  fi

  local_has_vip && oci_has_vip
}

vip_stop() {
  vip_validate || return $?
  local vnic
  vnic="$(get_local_vnic)" || return $OCF_ERR_CONFIGURED

  if local_has_vip; then
    ip addr del "$VIP/$PREFIX" dev "$IFACE" || return $OCF_ERR_GENERIC
  fi

  if oci_has_vip; then
    "$OCI" network vnic unassign-private-ip \
      --vnic-id "$vnic" \
      --ip-address "$VIP" \
      --auth instance_principal >/dev/null 2>&1 || return $OCF_ERR_GENERIC

    for i in $(seq 1 15); do
      ! oci_has_vip && break
      sleep 1
    done
  fi

  if local_has_vip || oci_has_vip; then
    return $OCF_ERR_GENERIC
  fi
  return $OCF_SUCCESS
}

vip_monitor() {
  vip_validate >/dev/null 2>&1 || return $?
  local local_state=0
  local oci_state=0
  local_has_vip && local_state=1
  oci_has_vip && oci_state=1

  if [ "$local_state" -eq 1 ] && [ "$oci_state" -eq 1 ]; then
    return $OCF_SUCCESS
  fi
  if [ "$local_state" -eq 0 ] && [ "$oci_state" -eq 0 ]; then
    return $OCF_NOT_RUNNING
  fi
  return $OCF_ERR_GENERIC
}

case "$1" in
  start) vip_start ;;
  stop) vip_stop ;;
  monitor|status) vip_monitor ;;
  validate-all) vip_validate ;;
  meta-data)
    # The installed version includes the full metadata XML with parameter
    # and action definitions, omitted here for brevity.
    ;;
  *) exit $OCF_ERR_UNIMPLEMENTED ;;
esac
