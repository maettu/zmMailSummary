# zmMailSummary
Get a summary of mails in a Zimbra folder for a defined time period.

The summary is a mail that gets sent to each user.

Example
-------
You have a spam filter that moves mail into /Junk.
Your would rather get a mail every day with information about new mails in /Junk instead of skimming the junk folder yourself.

The output would look like so (and you can of course change the template)

    Dear foo@bar.com,

    You have 42 new mails in your junk folder (last 24 hours).

    summary:

    date           from           subject
    -------------- -------------- ---------------------
    17/02/05 06:33 boo@evil.org   we'd love to spam you
    17/02/05 07:15 sp@am.hidden   catch me when I spam
    ...

Setup
-----
    ./bootstrap
    ./configure
    make

Release
-------
    make dist

Deploy
------
    ./configure
    make

Pass .tar.gz on to customer

Implement
--------

    tar -xvzf zmmailsummary-(version).tar.gz
    cd zmmailsummary-(version)

- make file "etc/exclude_list" and put in addressees to skip. One mail address per line.
- copy "etc/zmmailsummary.cfg.dist" to "etc/zmmailsummary.cfg" and edit
- edit "templates/mail_template.txt.ep"

then, run

    ./configure
    make
    (make install)

Testing: instead of "make install", run from the current directory.

Test / Debug
------------
print debug messages and only send to mailboxes matching an account

    bin/zmMailSummary provide -d --account-names=matthias

Sends mail to all accounts that contain "matthias" somewhere in their name.

Run
---
    bin/zmMailSummary provide

Send mail to all users with new mail in the selected folder.
