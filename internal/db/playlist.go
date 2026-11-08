// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/google/uuid"
)

// PlaylistXML is the file next to master.db where Rekordbox 6/7 mirrors the playlist tree.
const PlaylistXML = "masterPlaylists6.xml"

// ErrPlaylistExists means a playlist (or folder) already has the requested name.
var ErrPlaylistExists = errors.New("playlist already exists")

// NewPlaylist is a playlist CreatePlaylist inserted.
type NewPlaylist struct {
	ID, ParentID, Name string
	Created            time.Time
	Tracks             int
}

// CreatePlaylist adds a plain playlist called name holding contentIDs in order (duplicates
// kept), at the end of the root or of the folder called folder. It refuses a name that is
// already taken and content IDs that aren't in the library. Like the cue writes it leaves
// usn and agentRegistry alone (docs/decisions/0016-create-playlists-from-histories.md).
func CreatePlaylist(tx *sql.Tx, name, folder string, contentIDs []string) (*NewPlaylist, error) {
	var n int
	if err := tx.QueryRow("select count(*) from djmdPlaylist where rb_local_deleted=0 and Name=?", name).
		Scan(&n); err != nil {
		return nil, err
	}
	if n > 0 {
		return nil, fmt.Errorf("%w: '%s'", ErrPlaylistExists, name)
	}
	parent := "root"
	if folder != "" {
		var id sql.NullString
		err := tx.QueryRow("select ID from djmdPlaylist where rb_local_deleted=0 and Attribute=1 and Name=?", folder).
			Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("no playlist folder called '%s'", folder)
		}
		if err != nil {
			return nil, err
		}
		parent = id.String
	}
	for _, cid := range contentIDs {
		if err := tx.QueryRow("select count(*) from djmdContent where rb_local_deleted=0 and ID=?", cid).
			Scan(&n); err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, fmt.Errorf("track %s is not in the library", cid)
		}
	}
	var seq int
	if err := tx.QueryRow("select coalesce(max(Seq), 0) from djmdPlaylist where rb_local_deleted=0 and ParentID=?",
		parent).Scan(&seq); err != nil {
		return nil, err
	}
	used, err := newIDSource(tx, "djmdPlaylist")
	if err != nil {
		return nil, err
	}
	id, err := used.next()
	if err != nil {
		return nil, err
	}
	created := time.Now()
	ts := stamp(created)
	if _, err := tx.Exec(`insert into djmdPlaylist (ID, Seq, Name, ImagePath, Attribute, ParentID, SmartList, UUID,
                rb_data_status, rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn,
                created_at, updated_at) values (?, ?, ?, NULL, 0, ?, NULL, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)`,
		id, seq+1, name, parent, uuid.NewString(), ts, ts); err != nil {
		return nil, err
	}
	for i, cid := range contentIDs {
		if _, err := tx.Exec(`insert into djmdSongPlaylist (ID, PlaylistID, ContentID, TrackNo, UUID, rb_data_status,
                rb_local_data_status, rb_local_deleted, rb_local_synced, usn, rb_local_usn, created_at, updated_at)
                values (?, ?, ?, ?, ?, 0, 0, 0, 0, NULL, NULL, ?, ?)`,
			uuid.NewString(), id, cid, i+1, uuid.NewString(), ts, ts); err != nil {
			return nil, err
		}
	}
	return &NewPlaylist{ID: id, ParentID: parent, Name: name, Created: created, Tracks: len(contentIDs)}, nil
}

// xmlID is a djmdPlaylist ID as masterPlaylists6.xml writes it: upper-case hex, root "0".
func xmlID(id string) (string, error) {
	if id == "root" || id == "" {
		return "0", nil
	}
	n, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return "", fmt.Errorf("playlist ID %q is not a number", id)
	}
	return fmt.Sprintf("%X", n), nil
}

// AddPlaylistNode returns masterPlaylists6.xml with a NODE for p appended to PLAYLISTS, in
// the file's own line endings and indentation.
func AddPlaylistNode(doc []byte, p NewPlaylist) ([]byte, error) {
	id, err := xmlID(p.ID)
	if err != nil {
		return nil, err
	}
	parent, err := xmlID(p.ParentID)
	if err != nil {
		return nil, err
	}
	if bytes.Contains(doc, []byte(`<NODE Id="`+id+`"`)) {
		return nil, fmt.Errorf("a node with Id %s is already there", id)
	}
	end := bytes.LastIndex(doc, []byte("</PLAYLISTS>"))
	if end < 0 {
		return nil, errors.New("no </PLAYLISTS> element")
	}
	lineStart := bytes.LastIndexByte(doc[:end], '\n') + 1
	nl := "\n"
	if bytes.Contains(doc, []byte("\r\n")) {
		nl = "\r\n"
	}
	indent := "    "
	if i := bytes.Index(doc, []byte("<NODE ")); i >= 0 {
		indent = string(doc[bytes.LastIndexByte(doc[:i], '\n')+1 : i])
	}
	node := fmt.Sprintf(`%s<NODE Id="%s" ParentId="%s" Attribute="0" Timestamp="%d" Lib_Type="0" CheckType="0"/>%s`,
		indent, id, parent, p.Created.UnixMilli(), nl)
	out := make([]byte, 0, len(doc)+len(node))
	out = append(append(append(out, doc[:lineStart]...), node...), doc[lineStart:]...)
	return out, nil
}

// WritePlaylist creates the playlist with SafeWrite, adding its node to masterPlaylists6.xml
// in the same step when that file exists.
func WritePlaylist(masterDB, backupDir, name, folder string, contentIDs []string) (*Stats, error) {
	return writePlaylist(masterDB, name, folder, contentIDs,
		func(fn ApplyFunc, sides ...Sidecar) (*Stats, error) {
			return SafeWrite(masterDB, backupDir, fn, sides...)
		})
}

// writePlaylist is WritePlaylist with the write itself passed in (for tests).
func writePlaylist(masterDB, name, folder string, contentIDs []string,
	write func(ApplyFunc, ...Sidecar) (*Stats, error)) (*Stats, error) {
	var created *NewPlaylist
	fn := func(tx *sql.Tx) (*Stats, error) {
		p, err := CreatePlaylist(tx, name, folder, contentIDs)
		if err != nil {
			return nil, err
		}
		created = p
		return NewStats("playlist", p.Name, "playlist_id", p.ID, "tracks", p.Tracks), nil
	}
	var sides []Sidecar
	xml := filepath.Join(filepath.Dir(masterDB), PlaylistXML)
	if _, err := os.Stat(xml); err == nil {
		sides = append(sides, Sidecar{Path: xml, Update: func(old []byte) ([]byte, error) {
			return AddPlaylistNode(old, *created)
		}})
	}
	return write(fn, sides...)
}
