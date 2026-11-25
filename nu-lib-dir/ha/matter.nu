# The Matter Server add-on's log: when devices dropped off.
#
# The server logs a device offline when it loses the connection
# (`ClientNode server-2-134b.@1:12 is offline`), and online when it reconnects
# (`… @1:12 is online`). Each span in between is an outage: a remote's presses
# are lost then, though Home Assistant can still show it as available.
# Restarting the server also logs every device offline, until it reconnects to
# them a minute or two later.
#
# A device usually goes offline shortly after its subscription times out
# because a report is overdue (`Subscription … to peer @1:12 timed out after
# 15m 38s`), so it went quiet earlier: `last_heard` is when its last report
# arrived, or empty if no subscription was lost, as in a restart. Sleepy
# Thread devices report at least every 15 minutes, so `last_heard` is usually
# 16 to 20 minutes before `offline`.
#
# Node IDs are decimal, as Home Assistant shows them; the log writes them in hex
# after the fabric index (`@1:12` is node 18). Their names in Home Assistant
# come from the matter-nodes.json that `ha download` saves next to the log.
# Matter Server logs in Home Assistant's time zone, like the border router.

use _download.nu [MATTER_LOG NODE_NAMES]
use _time.nu [TIME_FORMAT DAY_FORMAT count-by-day]

const TIME_PATTERN = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}'

# The lines used. Each captures the node (in hex) under the name of what
# happened to it.
const EVENT_PATTERN = (
  '^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) +\S+ +\S+ +(?:'
  + 'Subscription \S+ to peer @\d+:(?<timed_out>[0-9a-f]+) timed out after (?<after>.+)'
  + '|Subscription successful « @\d+:(?<subscribed>[0-9a-f]+)\b.*'
  + '|\S+\.@\d+:(?<offline>[0-9a-f]+) is offline'
  + '|\S+\.@\d+:(?<online>[0-9a-f]+) is online'
  + '|Removing @\d+:(?<removed>[0-9a-f]+)'
  + ')$'
)

# List outages: when each device was last heard from, went offline, and came
# back online, and how long it was offline. Reads the downloaded log, or the
# one at `path`.
export def disconnects [
  path: path = $MATTER_LOG
  --since: string  # only outages from this local time on, e.g. 2026-10-11 or '2026-10-11 14:30'
  --daily          # count outages per day, by node, instead of listing them
]: nothing -> table {
  let since = if $since != null { $since | into datetime }
  let log = read-log $path
  let outages = $log.outages | where {|o| $since == null or $o.offline >= $since }
  if $daily {
    let rows = $outages | each {|o| {time: $o.offline, column: $"node ($o.node)"} }
    let nodes = $outages | each { $in.node } | uniq | sort | each {|node| $"node ($node)" }
    count-by-day $rows $nodes ($since | default $log.start) $log.end
  } else {
    $outages | each {|o| {
      node: $o.node
      name: (node-name $log $o.node)
      last_heard: (if $o.last_heard != null { $o.last_heard | format date $TIME_FORMAT })
      offline: ($o.offline | format date $TIME_FORMAT)
      online: (if $o.online != null { $o.online | format date $TIME_FORMAT } else { $o.unended })
      down: ($o.until - $o.offline | round-minutes)
    } }
  }
}

# Each node's outages and downtime, per period: a row per --bin of time, a week
# from Sunday to Saturday unless given another number of days, with the total
# downtime and a table of the nodes that were down then. A node's `outages`
# are the ones that began in the period, and its `down` is all its time
# offline then, including from outages that began earlier. `note` says if it's
# still offline or was removed. The first and last periods only cover
# what the log does. Reads the downloaded log, or the one at `path`.
export def downtime [
  path: path = $MATTER_LOG
  --bin: duration = 1wk  # each period's length, in whole days, starting on Sundays
]: nothing -> table {
  let days = $bin / 1day
  if $days < 1 or $days != ($days | math floor) {
    error make {
      msg: "--bin must be a whole number of days"
      label: {text: "e.g. 1day or 2wk", span: (metadata $bin).span}
    }
  }
  let log = read-log $path
  periods $log.start $log.end ($days | into int) | each {|p|
    let nodes = nodes-down $log.outages $p.from $p.to | each {|node|
      let d = node-downtime $log.outages $node $p.from $p.to
      {node: $node, name: (node-name $log $node), outages: $d.outages, down: $d.down, note: (node-note $log $node)}
    }
    {
      from: ($p.from | format date $DAY_FORMAT)
      to: ($p.to - 1ns | format date $DAY_FORMAT)
      down: ($nodes | reduce --fold 0sec {|n, total| $total + $n.down })
      nodes: $nodes
    }
  }
}

# Periods of `days` days, each starting at midnight on a Sunday or every
# `days` days after one, covering `start` to `end`. The first and last are cut
# short to fit.
def periods [start: datetime, end: datetime, days: int]: nothing -> table {
  # Stepping whole days from noon, a DST change can't move the date.
  let noon = $start | format date '%Y-%m-%d 12:00:00' | into datetime
  let sunday = $noon - (($start | format date '%w' | into int) * 1day) | format date '%Y-%m-%d'
  let past_end = ($end | format date '%Y-%m-%d 12:00:00' | into datetime) + ($days * 1day) | format date '%Y-%m-%d'
  seq date --begin-date $sunday --end-date $past_end --increment $days
  | each { into datetime }
  | window 2
  | where {|w| $w.0 < $end and $w.1 > $start }
  | each {|w| {
      from: (if $w.0 > $start { $w.0 } else { $start })
      to: (if $w.1 < $end { $w.1 } else { $end })
    } }
}

# The log's outages, in order, the nodes removed, their names (if downloaded),
# and when the log starts and ends.
def read-log [path: path]: nothing -> record {
  let lines = open --raw $path | lines | ansi strip
  let times = $lines | where $it =~ $TIME_PATTERN
  if ($times | is-empty) {
    error make --unspanned {msg: $"No Matter Server lines in ($path)"}
  }
  let end = $times | last | str substring 0..22 | into datetime
  let events = $lines | parse --regex $EVENT_PATTERN | update time { into datetime }
  let names = $path | path dirname | path join $NODE_NAMES
  {
    start: ($times | first | str substring 0..22 | into datetime)
    end: $end
    outages: (outages $events $end)
    removed: (
      $events
      | where removed != null
      | each {|e| {node: ($e.removed | into int --radix 16), time: $e.time} }
      | uniq-by node
    )
    names: (if ($names | path exists) { open $names } else { [] })
  }
}

# Pairs a node's "is offline" with its next "is online", in order of when they
# began. Outages without an end last until the node was 'removed', or are
# 'still offline' and last until `log_end`.
def outages [events: table, log_end: datetime]: nothing -> table {
  # node -> when its last report arrived, if its subscription timed out since
  # it last subscribed or came online.
  mut lost = {}
  mut open = {}  # node -> {last_heard, offline}
  mut found = []
  for e in $events {
    if $e.timed_out != null {
      let node = $e.timed_out
      let last_heard = $e.time - (parse-duration $e.after)
      $lost = $lost | upsert $node $last_heard
      # A timeout logged after the device went offline still says when it was
      # last heard.
      if $node in ($open | columns) and ($open | get $node).last_heard == null {
        $open = $open | upsert $node ($open | get $node | upsert last_heard $last_heard)
      }
    } else if $e.subscribed != null {
      $lost = $lost | upsert $e.subscribed null
    } else if $e.offline != null {
      let node = $e.offline
      if $node not-in ($open | columns) {
        $open = $open | insert $node {last_heard: ($lost | get -o $node), offline: $e.time}
      }
    } else {
      let node = $e.online | default $e.removed
      $lost = $lost | upsert $node null
      if $node in ($open | columns) {
        let unended = if $e.online == null { 'removed' }
        $found = $found | append (outage $node ($open | get $node) $e.time $unended)
        $open = $open | reject $node
      }
    }
  }
  let unended = $open | items {|node, o| outage $node $o $log_end 'still offline' }
  $found ++ $unended | sort-by offline
}

# An outage record. It lasted until `until`, and either ended then (`online`)
# or didn't, for the reason in `unended`.
def outage [
  node: string
  o: record
  until: datetime
  unended: oneof<string, nothing>
]: nothing -> record {
  {
    node: ($node | into int --radix 16)
    last_heard: $o.last_heard
    offline: $o.offline
    online: (if $unended == null { $until })
    unended: $unended
    until: $until
  }
}

# matter.js durations, e.g. "15m 38s", "9.5s", or "2h 25m 10s".
def parse-duration [text: string]: nothing -> duration {
  $text
  | split row ' '
  | each {|part|
      let p = $part | parse --regex '^(?<n>\d+(?:\.\d+)?)(?<unit>ms|d|h|m|s)$' | first
      ($p.n | into float) * (match $p.unit { 'd' => 1day, 'h' => 1hr, 'm' => 1min, 's' => 1sec, 'ms' => 1ms })
    }
  | math sum
}

# Nodes with an outage between `from` and `to`, in order.
def nodes-down [outages: table, from: datetime, to: datetime]: nothing -> list<int> {
  $outages | where {|o| $o.offline < $to and $o.until > $from } | each { $in.node } | uniq | sort
}

# How many of a node's outages began between `from` and `to`, and how long it
# was offline then, including outages that began earlier.
def node-downtime [outages: table, node: int, from: datetime, to: datetime]: nothing -> record {
  let mine = $outages | where node == $node
  {
    outages: ($mine | where offline >= $from and offline < $to | length)
    down: ($mine | reduce --fold 0sec {|o, total|
      let start = if $o.offline > $from { $o.offline } else { $from }
      let end = if $o.until < $to { $o.until } else { $to }
      if $end > $start { $total + ($end - $start) } else { $total }
    } | round-minutes)
  }
}

# A node's name in Home Assistant, if known.
def node-name [log: record, node: int]: nothing -> oneof<string, nothing> {
  $log.names | where node == $node | get -o 0.name
}

# Whether a node is still offline when the log ends, or was removed.
def node-note [log: record, node: int]: nothing -> oneof<string, nothing> {
  let unended = $log.outages | where node == $node and unended == 'still offline'
  let removed = $log.removed | where node == $node
  if ($unended | is-not-empty) {
    $"offline since (($unended | first).offline | format date $TIME_FORMAT)"
  } else if ($removed | is-not-empty) {
    $"removed (($removed | first).time | format date $TIME_FORMAT)"
  }
}

def round-minutes []: duration -> duration {
  ($in / 1min | math round) * 1min
}
