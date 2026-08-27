import { BookWithData, PageStat } from '@koinsight/common/types';
import { Book } from '@koinsight/common/types/book';
import { Anchor, Flex, Loader, Switch, Title } from '@mantine/core';
import { startOfDay } from 'date-fns/startOfDay';
import { uniq } from 'ramda';
import { JSX, useCallback, useMemo, useState } from 'react';
import { Link } from 'react-router';
import { useBooks } from '../api/books';
import { usePageStats } from '../api/use-page-stats';
import { Calendar, CalendarEvent } from '../components/calendar/calendar';
import { getBookPath } from '../routes';
import { CalendarBookDay } from '../components/calendar/calendar-book-day';

type DayData = {
  events: PageStat[];
};

const MINIMUM_SESSION_DURATION = 60;

export function CalendarPage(): JSX.Element {
  const { data: books, isLoading } = useBooks();
  const [hideShortSessions, setHideShortSessions] = useState(false);
  const {
    data: { stats: events },
    isLoading: eventsLoading,
  } = usePageStats();

  const calendarEvents = useMemo<Record<string, CalendarEvent<DayData>>>(() => {
    if (eventsLoading || !events) {
      return {};
    }

    const eventsList = events.reduce<Record<string, CalendarEvent<DayData>>>((acc, event) => {
      const date = startOfDay(event.start_time);
      const key = date.toISOString();

      acc[key] = {
        date,
        data: acc[key]?.data?.events
          ? { events: [...acc[key].data.events, event] }
          : { events: [event] },
      };

      return acc;
    }, {});

    if (!hideShortSessions) {
      return eventsList;
    }

    return Object.entries(eventsList).reduce<Record<string, CalendarEvent<DayData>>>(
      (acc, [key, entry]) => {
        const dayEvents = entry.data?.events ?? [];

        const durationByBook = dayEvents.reduce<Record<string, number>>((totals, event) => {
          totals[event.book_md5] = (totals[event.book_md5] ?? 0) + event.duration;
          return totals;
        }, {});

        const filteredEvents = dayEvents.filter(
          (event) => durationByBook[event.book_md5] >= MINIMUM_SESSION_DURATION
        );

        if (filteredEvents.length > 0) {
          acc[key] = { ...entry, data: { events: filteredEvents } };
        }

        return acc;
      },
      {}
    );
  }, [events, eventsLoading, hideShortSessions]);

  const getBookByMd5 = useCallback(
    (md5: Book['md5']) => books?.find((book) => book.md5 === md5),
    [books]
  );

  const getBookNames = useCallback(
    (data: DayData) => {
      const uniqueBookMd5s = uniq(data.events.map(({ book_md5 }) => book_md5));
      const eventBooks = uniqueBookMd5s.map((id) => getBookByMd5(id)).filter(Boolean) as BookWithData[];

      return eventBooks.map((book) => {

        const bookDayData = data.events.filter((event) => event.book_md5 === book.md5);
        
        return (
          <>
            <Anchor key={book.id} component={Link} to={getBookPath(book.id)}>
              {book.title}
            </Anchor>
            <br />
            <CalendarBookDay book={book} data={{ events: bookDayData }} />
            <br />
          </>
        );
      });
    },
    [getBookByMd5]
  );

  if (isLoading || !books || !events || eventsLoading) {
    return (
      <Flex justify="center" align="center" h="100%">
        <Loader />
      </Flex>
    );
  }

  return (
    <>
      <Flex justify="space-between" align="center" mb="xl" wrap="wrap" gap="md">
        <Title>Calendar</Title>
        <Switch
          label="Hide entries under a minute"
          checked={hideShortSessions}
          onChange={(event) => setHideShortSessions(event.currentTarget.checked)}
        />
      </Flex>
      <Calendar<DayData>
        events={calendarEvents}
        dayRenderer={(data) => getBookNames(data).map((el) => <div>{el}</div>)}
      />
    </>
  );
}
