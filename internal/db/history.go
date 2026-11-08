// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ------------------------------------------------------------------ histories

// History is one play history (djmdHistory, Attribute 0; the year / month folders are
// left out). Rekordbox names imported CDJ histories "HISTORY yyyy-mm-dd (n)".
type History struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Created string `json:"created"` // DateCreated, "yyyy-mm-dd hh:mm:ss" local time
	Tracks  int    `json:"tracks"`
}

// Date is the history's day (yyyy-mm-dd), "" when unknown.
func (h History) Date() string {
	if len(h.Created) >= 10 {
		return h.Created[:10]
	}
	return ""
}

// ListHistories returns the play histories, oldest first.
func ListHistories(q Querier) ([]History, error) {
	rows, err := q.Query(`select h.ID, h.Name, coalesce(h.DateCreated, ''),
                (select count(*) from djmdSongHistory s where s.HistoryID = h.ID and s.rb_local_deleted = 0)
                from djmdHistory h where h.rb_local_deleted = 0 and coalesce(h.Attribute, 0) = 0
                order by h.DateCreated, h.Seq`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []History
	for rows.Next() {
		var h History
		var id, name sql.NullString
		if err := rows.Scan(&id, &name, &h.Created, &h.Tracks); err != nil {
			return nil, err
		}
		h.ID, h.Name = id.String, name.String
		out = append(out, h)
	}
	return out, rows.Err()
}

// HistoryTrack is one row of a history. Created is when Rekordbox wrote the row (when the
// history was imported, not when the track was played), kept for diagnostics only.
type HistoryTrack struct {
	PlaylistTrack
	Created string `json:"created"`
}

// ErrNoHistory means no history has the requested name.
var ErrNoHistory = errors.New("no such history")

// LoadHistory returns the history and its tracks in TrackNo order (play order). A track
// the CDJs loaded twice appears twice.
func LoadHistory(q Querier, name string) (History, []HistoryTrack, error) {
	var h History
	var id sql.NullString
	err := q.QueryRow(`select ID, coalesce(DateCreated, '') from djmdHistory
                where rb_local_deleted = 0 and coalesce(Attribute, 0) = 0 and Name = ?`, name).Scan(&id, &h.Created)
	if errors.Is(err, sql.ErrNoRows) {
		return h, nil, fmt.Errorf("%w: no history called '%s'", ErrNoHistory, name)
	}
	if err != nil {
		return h, nil, err
	}
	h.ID, h.Name = id.String, name
	rows, err := q.Query(`select sh.TrackNo, c.ID, c.Title, c.BPM, k.ScaleName, sh.created_at
                from djmdSongHistory sh join djmdContent c on c.ID = sh.ContentID
                left join djmdKey k on k.ID = c.KeyID
                where sh.HistoryID = ? and sh.rb_local_deleted = 0 order by sh.TrackNo`, h.ID)
	if err != nil {
		return h, nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []HistoryTrack
	for rows.Next() {
		var no sql.NullInt64
		var cid, title, key, created sql.NullString
		var bpm sql.NullFloat64
		if err := rows.Scan(&no, &cid, &title, &bpm, &key, &created); err != nil {
			return h, nil, err
		}
		out = append(out, HistoryTrack{PlaylistTrack{No: int(no.Int64), ID: cid.String, Title: title.String,
			BPM: bpm.Float64 / 100, Key: key.String}, created.String})
	}
	h.Tracks = len(out)
	return h, out, rows.Err()
}

// ------------------------------------------------------------------ tags

// Tags are a track's library metadata, as the export writes them.
type Tags struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Artist      string  `json:"artist"`
	Composer    string  `json:"composer"`
	Remixer     string  `json:"remixer"`
	OrgArtist   string  `json:"original_artist"`
	Album       string  `json:"album"`
	AlbumArtist string  `json:"album_artist"`
	Genre       string  `json:"genre"`
	Label       string  `json:"label"`
	Key         string  `json:"key"`
	Year        int     `json:"year"`
	BPM         float64 `json:"bpm"`
	Comment     string  `json:"comment"`
	FolderPath  string  `json:"folder_path"`
}

// LoadTags returns the tags of the given tracks by ID (unknown IDs are left out).
func LoadTags(q Querier, ids []string) (map[string]Tags, error) {
	out := map[string]Tags{}
	if len(ids) == 0 {
		return out, nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	rows, err := q.Query(`select c.ID, c.Title, ar.Name, co.Name, re.Name, oa.Name, al.Name, aa.Name, g.Name, l.Name,
                k.ScaleName, c.ReleaseYear, c.BPM, c.Commnt, c.FolderPath
                from djmdContent c
                left join djmdArtist ar on ar.ID = c.ArtistID
                left join djmdArtist co on co.ID = c.ComposerID
                left join djmdArtist re on re.ID = c.RemixerID
                left join djmdArtist oa on oa.ID = c.OrgArtistID
                left join djmdAlbum al on al.ID = c.AlbumID
                left join djmdArtist aa on aa.ID = al.AlbumArtistID
                left join djmdGenre g on g.ID = c.GenreID
                left join djmdLabel l on l.ID = c.LabelID
                left join djmdKey k on k.ID = c.KeyID
                where c.ID in (?`+strings.Repeat(",?", len(ids)-1)+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var s [14]sql.NullString
		var year sql.NullInt64
		var bpm sql.NullFloat64
		if err := rows.Scan(&s[0], &s[1], &s[2], &s[3], &s[4], &s[5], &s[6], &s[7], &s[8], &s[9], &s[10], &year, &bpm,
			&s[11], &s[12]); err != nil {
			return nil, err
		}
		t := Tags{ID: s[0].String, Title: s[1].String, Artist: s[2].String, Composer: s[3].String, Remixer: s[4].String,
			OrgArtist: s[5].String, Album: s[6].String, AlbumArtist: s[7].String, Genre: s[8].String, Label: s[9].String,
			Key: s[10].String, Year: int(year.Int64), BPM: bpm.Float64 / 100, Comment: s[11].String, FolderPath: s[12].String}
		out[t.ID] = t
	}
	return out, rows.Err()
}
