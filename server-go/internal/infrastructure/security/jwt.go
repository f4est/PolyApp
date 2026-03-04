package security

import (
	"errors"
	"time"

	"polyapp/server-go/internal/domain/entity"

	"github.com/golang-jwt/jwt/v5"
)

type JWTService struct {
	secret []byte
}

func NewJWTService(secret string) *JWTService {
	return &JWTService{secret: []byte(secret)}
}

type appClaims struct {
	Sub  uint   `json:"sub"`
	Role string `json:"role"`
	SID  string `json:"sid"`
	jwt.RegisteredClaims
}

func (s *JWTService) Generate(claims entity.TokenClaims) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, appClaims{
		Sub:  claims.UserID,
		Role: claims.Role,
		SID:  claims.SessionID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(claims.ExpiresAt),
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
		},
	})
	return token.SignedString(s.secret)
}

func (s *JWTService) Parse(tokenString string) (*entity.TokenClaims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &appClaims{}, func(token *jwt.Token) (any, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return s.secret, nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := token.Claims.(*appClaims)
	if !ok || !token.Valid {
		return nil, errors.New("invalid token")
	}
	return &entity.TokenClaims{
		UserID:    claims.Sub,
		Role:      claims.Role,
		SessionID: claims.SID,
		ExpiresAt: claims.ExpiresAt.Time,
	}, nil
}
