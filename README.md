# Druna rebar plugin

Druna is a simple rebar plugin to make distribution of
compiled Erlang code a bit easier.

It's still in development, but at the moment it can fetch
Erlang Archive Files and get the ready in your rebar
application. Keep in mind it does expect a specific
web path.

I'm working on a server that can provide those paths, as
well as a search interface on it.

## The story so far

Druna is able to:

* Download the zipped dependencies
* Unzip them to the correct path
* Load the beams into the code path
* Create zipped dependencies from applications


Druna isn't able to:

* "Publish" dependencies
