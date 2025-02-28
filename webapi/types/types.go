package types

//go:generate stringer -type=APIErrorCode -output=types_err.go

import (
	"fmt"
	"time"
)

type APIErrorCode int //nolint:revive

// List of known/expected error codes
// re-run `go generate ./...` when updating
const (
	ErrInvalidRequest            APIErrorCode = 4400
	ErrUnauthorizedAccess        APIErrorCode = 4401
	ErrSystemTemporarilyDisabled APIErrorCode = 4503

	ErrOversizedPiece                  APIErrorCode = 4011
	ErrStorageProviderSuspended        APIErrorCode = 4012
	ErrStorageProviderIneligibleToMine APIErrorCode = 4013

	ErrUnclaimedPieceCID         APIErrorCode = 4020
	ErrProviderHasReplica        APIErrorCode = 4021
	ErrTenantsOutOfDatacap       APIErrorCode = 4022
	ErrTooManyReplicas           APIErrorCode = 4023
	ErrProviderAboveMaxInFlight  APIErrorCode = 4024
	ErrReplicationRulesViolation APIErrorCode = 4029 // catch-all for when there is no common rejection theme for competing tenants

	ErrExternalReservationRefused APIErrorCode = 4030 // some tenants are looking to add an additional check on their end
)

// ResponseEnvelope is the structure wrapping all responses from the deal engine
type ResponseEnvelope struct {
	RequestID          string          `json:"request_id,omitempty"`
	ResponseTime       time.Time       `json:"response_timestamp"`
	ResponseStateEpoch int64           `json:"response_state_epoch,omitempty"`
	ResponseCode       int             `json:"response_code"`
	ErrCode            int             `json:"error_code,omitempty"`
	ErrSlug            string          `json:"error_slug,omitempty"`
	ErrLines           []string        `json:"error_lines,omitempty"`
	InfoLines          []string        `json:"info_lines,omitempty"`
	ResponseEntries    *int            `json:"response_entries,omitempty"`
	Response           []Piece         `json:"response"`
}

type isResponsePayload struct{}

type ResponsePayload interface { //nolint:revive
	is() isResponsePayload
}

// ResponsePendingProposals is the response payload returned by the .../pending_proposals endpoint
type ResponsePendingProposals struct {
	RecentFailures   []ProposalFailure `json:"recent_failures,omitempty"`
	PendingProposals []DealProposal    `json:"pending_proposals"`
}

// ResponseDealRequest is the response payload returned by the .../request_piece/{{PieceCid}} endpoint
type ResponseDealRequest struct {
	ReplicationCounts []TenantReplicationCounts `json:"tenant_replication_counts"`
	DealStartTime     *time.Time                `json:"deal_start_time,omitempty"`
	DealStartEpoch    *int64                    `json:"deal_start_epoch,omitempty"`
}

// ResponsePiecesEligible is the response payload returned by the .../eligible_pieces endpoint
type ResponsePiecesEligible []*Piece

func (ResponsePendingProposals) is() isResponsePayload { return isResponsePayload{} }
func (ResponseDealRequest) is() isResponsePayload      { return isResponsePayload{} }
func (ResponsePiecesEligible) is() isResponsePayload   { return isResponsePayload{} }

type ProposalFailure struct { //nolint:revive
	Tstamp   time.Time `json:"timestamp"`
	Err      string    `json:"error"`
	PieceCid string    `json:"piece_cid"`
	DealCid  string    `json:"deal_proposal_cid"`
}

type DealProposal struct { //nolint:revive
	DealCid        string       `json:"deal_proposal_cid"`
	HoursRemaining int          `json:"hours_remaining"`
	PieceSize      int64        `json:"piece_size"`
	PieceCid       string       `json:"piece_cid"`
	TenantID       int16        `json:"tenant_id"`
	StartTime      time.Time    `json:"deal_start_time"`
	StartEpoch     int64        `json:"deal_start_epoch"`
	ImportCMD      string       `json:"sample_import_cmd"`
	Sources        []FilSourceDAG  `json:"sources,omitempty"`
}

type TenantReplicationCounts struct { //nolint:revive
	TenantID int16 `json:"tenant_id"`

	MaxInFlightBytes int64 `json:"tenant_max_in_flight_bytes"`
	SpInFlightBytes  int64 `json:"actual_in_flight_bytes" db:"cur_in_flight_bytes"`

	MaxTotal     int16 `json:"tenant_max_total"`
	MaxOrg       int16 `json:"tenant_max_per_org"         db:"max_per_org"`
	MaxCity      int16 `json:"tenant_max_per_city"        db:"max_per_city"`
	MaxCountry   int16 `json:"tenant_max_per_country"     db:"max_per_country"`
	MaxContinent int16 `json:"tenant_max_per_continent"   db:"max_per_continent"`

	Total       int16 `json:"actual_total"                db:"cur_total"`
	InOrg       int16 `json:"actual_within_org"           db:"cur_in_org"`
	InCity      int16 `json:"actual_within_city"          db:"cur_in_city"`
	InCountry   int16 `json:"actual_within_country"       db:"cur_in_country"`
	InContinent int16 `json:"actual_within_continent"     db:"cur_in_continent"`

	DealAlreadyExists bool `json:"deal_already_exists"`
}

type Piece struct { //nolint:revive
	PieceCid         string       `json:"piece_cid"`
	PaddedPieceSize  uint64       `json:"padded_piece_size"`
	ClaimingTenants  []int16      `json:"tenants" db:"tenant_ids"`
	SampleRequestCmd string       `json:"sample_request_cmd"`
	Sources          []FilSourceDAG `json:"sources,omitempty"`
}

type DataSource interface { //nolint:revive
	SrcType() string
}

// FilSourceDAG represents an item retrievable from Filecoin using a block-transport protocol like Graphsync.
// Whenever possible users of the deal engine should default to alternative sources offering stream-protocols.
type FilSourceDAG struct {
	SourceType string `json:"source_type"`

	// filecoin specific
	DealID             int64      `json:"deal_id"`
	ProviderID         string     `json:"provider_id"`
	OriginalPayloadCid string     `json:"original_payload_cid"`
	DealExpiration     time.Time  `json:"deal_expiration"`
	IsFilplus          bool       `json:"is_filplus"`
	SectorID           *string    `json:"sector_id,omitempty"`
	SectorExpiration   *time.Time `json:"sector_expiration,omitempty"`
	SampleRetrieveCmd  string     `json:"sample_retrieve_cmd"`
}

func (s *FilSourceDAG) SrcType() string { return s.SourceType } //nolint:revive
var _ DataSource = &FilSourceDAG{}

func (s *FilSourceDAG) InitDerivedVals(pieceCid string) error { //nolint:revive
	s.SourceType = "FilecoinDAG"

	if s.ProviderID == "" || s.OriginalPayloadCid == "" {
		return fmt.Errorf("filecoin DAG-source object missing mandatory values: %#v", s)
	}

	s.SampleRetrieveCmd = fmt.Sprintf(
		"lotus client retrieve --provider %s --maxPrice 0 --allow-local --car '%s' $(pwd)/%s__%s.car",
		s.ProviderID,
		s.OriginalPayloadCid,
		TrimCidString(pieceCid),
		TrimCidString(s.OriginalPayloadCid),
	)

	return nil
}

const (
	cidTrimPrefix = 6
	cidTrimSuffix = 8
)

func TrimCidString(cs string) string { //nolint:revive
	if len(cs) <= cidTrimPrefix+cidTrimSuffix+2 {
		return cs
	}
	return cs[0:cidTrimPrefix] + "~" + cs[len(cs)-cidTrimSuffix:]
}
