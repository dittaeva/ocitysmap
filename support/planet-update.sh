#!/bin/sh

LOG_FILE="/home/thomas/maposmatic/planet-update.log"
PID_FILE="/home/thomas/maposmatic/planet-update.pid"

OSM2PGSQL="/home/thomas/maposmatic/osm2pgsql/osm2pgsql"
OSM2PGSQL_STYLE="/home/thomas/maposmatic/osm2pgsql/default.style"

OSMOSIS="/home/thomas/maposmatic/osmosis/osmosis-0.36/bin/osmosis"
OSMOSIS_WD="${HOME}/maposmatic/osmosis"
OSMOSIS_STATE="${OSMOSIS_WD}/state.txt"
OSMOSIS_CONFIG="${OSMOSIS_WD}/configuration.txt"

CURRENT_OSC="${OSMOSIS_WD}/changes.$$.osc.gz"

log()
{
  echo "`date +"%Y-%m-%d %H:%M:%S"` - planet-update@$$ - $1" >> ${LOG_FILE}
}

error()
{
  log "ERROR: $1"

  log "Resetting state..."
  rm -f ${PID_FILE} ${CURRENT_OSC}
  cp -f ${OSMOSIS_WD}/last.state.txt ${OSMOSIS_STATE}

  echo "ERROR: $1"
  tail "${LOG_FILE}"
}

if [ -s "${PID_FILE}" ] ; then
  # If the update process is running, check for how long it has been running
  # and kill it if it has been more than one hour.
  NOW=`date +%s`
  START=`stat -c %Y "${PID_FILE}"`
  DELTA=`expr $NOW - $START`
  if [ $DELTA -lt 3600 ] ; then
    # Exit silently
    exit 0
  fi

  # Kill the osmosis and osm2pgsql process
  log "Killing stalled osmosis and osm2pgsql processes before starting over..."
  cp -f ${OSMOSIS_WD}/last.state.txt ${OSMOSIS_WD}/last.state.txt.$$
  ps aux | grep "${OSMOSIS}" | grep -v grep | awk '{print $2}' | xargs kill -9 2>&1 > /dev/null
  ps aux | grep "${OSM2PGSQL}" | grep -v grep | awk '{print $2}' | xargs kill -9 2>&1 > /dev/null
fi

if [ -e "${STOP_FILE}" ] ; then
  echo "stop requested."
  exit 1
fi

echo $$ > "${PID_FILE}"
log "log restarted."

if [ ! -s ${OSMOSIS_STATE} ] ; then
  error "No state file! Can't continue!"
  exit 2
fi

interval=`cat ${OSMOSIS_CONFIG} | \
  grep -e '^maxInterval' | awk '{print $3}'`
rep=`cat ${OSMOSIS_STATE} |\
	grep 'timestamp' |\
	awk '{split($0, a, "="); print a[2]}' |\
	tr 'T' ' ' |\
	xargs -I{} date --utc --date "{}" +"%Y-%m-%d %H:%M:%S"`

log "Retreiving ${interval}s worth of updates starting at ${rep} UTC..."
cp -f ${OSMOSIS_STATE} ${OSMOSIS_WD}/last.state.txt
if ! ${OSMOSIS} --read-replication-interval workingDirectory=${OSMOSIS_WD} --simplify-change --write-xml-change ${CURRENT_OSC} 1>&2 2>> "${LOG_FILE}" ; then
  error "Osmosis error. Aborting update!"
  exit 2
fi

nodes=`zgrep '<node' ${CURRENT_OSC} | wc -l`
ways=`zgrep '<way' ${CURRENT_OSC} | wc -l`
rels=`zgrep '<rel' ${CURRENT_OSC} | wc -l`

log "Expecting Node("$((${nodes}/1000))"k) Way("$((${ways}/1000))"k) Relation("$((${rels}/1000))"k)"

log "Importing diff..."
if ! ${OSM2PGSQL} -a -s -S ${OSM2PGSQL_STYLE} -d maposmatic -H localhost -U maposmatic ${CURRENT_OSC} 1>&2 2>> "${LOG_FILE}" ; then
  error "Osm2pgsql error. Update failed!"
  exit 3
fi

rep=`cat ${OSMOSIS_STATE} |\
	grep 'timestamp' |\
	awk '{split($0, a, "="); print a[2]}' |\
	tr 'T' ' ' |\
	xargs -I{} date --utc --date "{}" +"%Y-%m-%d %H:%M:%S"`
log "Update complete, now at ${rep} UTC (replication lag is `${HOME}/replag.sh`)."

# Update the maposmatic_admin table with the last update timestamp of
# the OSM data
echo "UPDATE maposmatic_admin SET last_update='${rep}';" | psql -h localhost -U maposmatic maposmatic2

rm -f ${PID_FILE} ${CURRENT_OSC}

exit 0

