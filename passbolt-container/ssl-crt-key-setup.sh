mkdir ssl && cd ./ssl
sudo openssl genrsa -out certificate.key 2048
# Use your actual Raspberry Pi IP address in the CN=
sudo openssl req -new -x509 -key certificate.key -out certificate.crt -days 365 -subj "/CN=192.168.0.102"
chmod 644 certificate.crt
chmod 600 certificate.key
