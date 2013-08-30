heartbeat.nimrod
================

This small script checks the alive status of a specified set of HTTP sites.  It sends an e-mail alert for down-time events.  Configuration can be done using a JSON file, whose sample is provided.  All currently recognised fields are shown therein.  Any additional fields specified are ignored.

_N.B._: The SMTP part does not work with 2-factor authentication currently.

This exercise is intended to develop familiarity with Nimrod!  Accordingly, the code may not (yet) follow Nimrod good practices.
