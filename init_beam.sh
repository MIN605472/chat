#!/bin/bash

pkill beam.smp
pkill erl
pkill epmd
sleep 2

COOKIE=CHOCOLATE
ADDR="127.0.0.1"
MEMBERS=""

for i in $(seq 7); do
    MEMBERS=$(printf "%s\nnode%d@%s\n" "${MEMBERS}" "${i}" "${ADDR}")
done
MEMBERS=$(printf "%s" "${MEMBERS}" | sed '/^$/d')
COORD=$(printf "%s" "${MEMBERS}" | head -n 1)
MEMBERS=$(printf "%s" "${MEMBERS}" | tail -n +2)
MEMBER_LIST="[$(printf "%s" "${MEMBERS}" | sed -e 's/\(.*\)/'"'"'\1'"'"'/g' | tr '\n' ',')]"
for MEMBER in ${MEMBERS}; do
    elixir --name ${MEMBER} \
        --erl '-kernel inet_dist_listen_min 32000' \
        --erl '-kernel inet_dist_listen_max 32009' \
        --cookie ${COOKIE} --detached --no-halt -S mix
done
elixir --name ${COORD} \
    --erl '-kernel inet_dist_listen_min 32000' \
    --erl '-kernel inet_dist_listen_max 32009' \
    --erl "-distributed_mutex members ${MEMBER_LIST}" \
    --cookie ${COOKIE} -S mix test
