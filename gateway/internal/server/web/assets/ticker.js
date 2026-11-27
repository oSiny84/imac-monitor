// Ticks every five seconds for the main page. Chrome slows the timers of a page that has been
// hidden for minutes to about once a minute, longer than the 20-second camera lease; a
// dedicated worker's timer is not slowed that way.
setInterval(() => postMessage("tick"), 5000);
