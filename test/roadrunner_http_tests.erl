-module(roadrunner_http_tests).
-include_lib("eunit/include/eunit.hrl").

http_date_now_format_matches_imf_fixdate_test() ->
    %% RFC 9110 §5.6.7: `Sun, 06 Nov 1994 08:49:37 GMT`. Validate the
    %% shape of the produced string — three-letter day, two-digit
    %% date, three-letter month, four-digit year, HH:MM:SS, GMT.
    Date = roadrunner_http:http_date_now(),
    %% Length is fixed: 29 bytes.
    ?assertEqual(29, byte_size(Date)),
    %% Last 3 chars are "GMT".
    ?assertEqual(~"GMT", binary:part(Date, 26, 3)),
    %% Day name is one of the seven.
    DayName = binary:part(Date, 0, 3),
    ?assert(
        lists:member(DayName, [~"Mon", ~"Tue", ~"Wed", ~"Thu", ~"Fri", ~"Sat", ~"Sun"])
    ),
    %% Month abbreviation is at offset 8..11.
    MonthName = binary:part(Date, 8, 3),
    ?assert(
        lists:member(MonthName, [
            ~"Jan",
            ~"Feb",
            ~"Mar",
            ~"Apr",
            ~"May",
            ~"Jun",
            ~"Jul",
            ~"Aug",
            ~"Sep",
            ~"Oct",
            ~"Nov",
            ~"Dec"
        ])
    ).
