Perl Windows Updates Downloader
===============================


This is program follows links to MS website for updates
and produces meta files with description notes about each update.

Mainly, program was wrotten to extract direct links to updates files.


Example usage
=============


```
shell> perl main.pl -N 8.8.8.8 -F mylinks.txt -D /tmp/winupdates
```

mylinks.txt contains URLs one per line:

```
http://www.microsoft.com/downloads/details.aspx?FamilyID=...
http://www.microsoft.com/downloads/details.aspx?FamilyID=...
http://www.microsoft.com/downloads/details.aspx?FamilyID=...
```

After that in /tmp/winupdates directory you will find files like:

```
NDP40-KB2861188-x64.exe.meta
NDP40-KB2861188-x86.exe.meta
```

And, for instance, NDP40-KB2861188-x64.exe.meta contains next info:

```
URL: http://www.microsoft.com/download/details.aspx?id=40505
File: NDP40-KB2861188-x64.exe
Size: 16.2 MB
Version: 4.0
Date: 04.10.2013
Download: http://download.microsoft.com/download/.../NDP40-KB2861188-x64.exe
References:
 http://support.microsoft.com/kb/2861188
 http://technet.microsoft.com/en-us/security/Bulletin/MS13-082
```
