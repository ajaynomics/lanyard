"""Keep URI property values whole in vobject, for the opt-in Radicale test.

Mount this directory at /config/python and set PYTHONPATH=/config/python
(test/integration/radicale_location_test.rb). An install's own Radicale
needs the same, or iPhone location reminders lose their longitude
(docs/calendar.md).

vobject 0.9.9 decodes every property it has no behavior for as TEXT and keeps
only the part before the first unescaped comma. RFC 5545 URI values are not
TEXT-escaped, so Apple's
X-APPLE-STRUCTURED-LOCATION;VALUE=URI:geo:<lat>,<lon> lost its longitude.
Pass VALUE=URI lines through untouched. Other properties keep vobject's
behaviour. Remove this file once vobject stops splitting URI values.
"""
from vobject import icalendar

_decode = icalendar.TextBehavior.decode.__func__
_encode = icalendar.TextBehavior.encode.__func__


def _is_uri(line):
    return any(v.upper() == "URI" for v in line.params.get("VALUE", []))


def _uri_safe_decode(cls, line):
    if line.encoded and _is_uri(line):
        line.encoded = False
        return
    _decode(cls, line)


def _uri_safe_encode(cls, line):
    if not line.encoded and _is_uri(line):
        line.encoded = True
        return
    _encode(cls, line)


icalendar.TextBehavior.decode = classmethod(_uri_safe_decode)
icalendar.TextBehavior.encode = classmethod(_uri_safe_encode)
