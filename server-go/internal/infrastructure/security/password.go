package security

import "golang.org/x/crypto/bcrypt"

type BcryptPasswordService struct{}

func (BcryptPasswordService) Hash(password string) (string, error) {
	raw, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func (BcryptPasswordService) Compare(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}
