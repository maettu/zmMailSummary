# zmMailSummary
Get a summary of mails in a Zimbra folder for a defined time period.

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
