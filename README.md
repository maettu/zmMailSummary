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
- copy "etc/zmmailsummary.cfg.dist" to "etc/zmmailsummary.cfg" and edit (see below)
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

config options
--------------
- folder: the folder you want to report on. Typically "Junk", but could be "Inbox" or any other folder.
- exclude_list: a list of mail addresses that do not get mails. One address per line
- report_back_days: How many days back mails are reported. This is "x days back until yesterday". E.g. setting to 1 will report all mails from yesterday. Setting to 10 reports all mails from today-10 days until yesterday.
- zimbra_url : the URL of the UI of your Zimbra. This is used for the links in the report. (Users can click those and directly find themselves in the reported mail.)
- default_language: the default locale. Accounts with locales different from those covered in "available_languages" will default to this. E.g. this is "de", available are "de and it" and an account is en_US, they will get a german mail.
- available_languages: a list of available languages. There is no checking if the default language is included in the available languages, but hey. :-)
- unsubscribe: users can unsubscribe from the reports by adding the specified string into "Settings -> Mail -> blacklist. The program reads this property and skips the user. Probably use something that is not a real mail address.
- mail_server: the server you send your reports through. Currently, there is no option to use an external service where you have to login, but that would be quite easy to patch into the program.
- mail_from: the address you want to see in "from:"
-change_to_address: useful e.g. for preproduction environments with real mail addresses. You will probably not want them to get your reports during testing. Supply what you find and what you want it to be replaced with. You could for example rewrite globally and send everything to your test account with [".*", "your_account@example.com"]

mails / templating:
-------------------
Have a look at the examples in templates/.
For each language in "available_languages", write 2 files. One txt, one html.
We are sending multipart/alternative mails.
The templates are Mojo::Templates. You can use the variables you see in the examples, and you can mix in Perl code.
Lines starting with % are Perl code.
<%= $user %> gets replaced with the value of the $user variable.

txt:
Just write the message body. Headers are added by the program.

html:
Just write ("Web style") html. The prgramm ads headers and DOCTYPE.
img tags are rewritten into "mail style". E.g. <img src='cid:filename.png'/>
Make sure the file "filename.png" is available in templates/.
The program detects the ctype by looking the suffix of the images. E.g. "filename.png" gets ctype "image/png". Make sure images are suffixed with what needs to go into ctype.
