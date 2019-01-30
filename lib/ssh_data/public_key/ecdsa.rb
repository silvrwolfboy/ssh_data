module SSHData
  module PublicKey
    class ECDSA < Base
      attr_reader :curve, :public_key_bytes, :openssl

      OPENSSL_CURVE_NAME_FOR_CURVE = {
        "nistp256" => "prime256v1",
        "nistp384" => "secp384r1",
        "nistp521" => "secp521r1",
      }

      CURVE_FOR_OPENSSL_CURVE_NAME = {
        "prime256v1" => "nistp256",
        "secp384r1"  => "nistp384",
        "secp521r1"  => "nistp521",
      }

      DIGEST_FOR_CURVE = {
        "nistp256" => OpenSSL::Digest::SHA256,
        "nistp384" => OpenSSL::Digest::SHA384,
        "nistp521" => OpenSSL::Digest::SHA512,
      }

      # Convert an SSH encoded ECDSA signature to DER encoding for verification with
      # OpenSSL.
      #
      # sig - A binary String signature from an SSH packet.
      #
      # Returns a binary String signature, as expected by OpenSSL.
      def self.openssl_signature(sig)
        r, rlen = Encoding.decode_mpint(sig, 0)
        s, slen = Encoding.decode_mpint(sig, rlen)

        if rlen + slen != sig.bytesize
          raise DecodeError, "unexpected trailing data"
        end

        OpenSSL::ASN1::Sequence.new([
          OpenSSL::ASN1::Integer.new(r),
          OpenSSL::ASN1::Integer.new(s)
        ]).to_der
      end

      # Convert an DER encoded ECDSA signature, as generated by OpenSSL to SSH
      # encoding.
      #
      # sig - A binary String signature, as generated by OpenSSL.
      #
      # Returns a binary String signature, as found in an SSH packet.
      def self.ssh_signature(sig)
        a1 = OpenSSL::ASN1.decode(sig)
        if a1.tag_class != :UNIVERSAL || a1.tag != OpenSSL::ASN1::SEQUENCE || a1.value.count != 2
          raise DecodeError, "bad asn1 signature"
        end

        r, s = a1.value
        if r.tag_class != :UNIVERSAL || r.tag != OpenSSL::ASN1::INTEGER || s.tag_class != :UNIVERSAL || s.tag != OpenSSL::ASN1::INTEGER
          raise DecodeError, "bad asn1 signature"
        end

        [Encoding.encode_mpint(r.value), Encoding.encode_mpint(s.value)].join
      end

      def initialize(algo:, curve:, public_key:)
        unless [ALGO_ECDSA256, ALGO_ECDSA384, ALGO_ECDSA521].include?(algo)
          raise DecodeError, "bad algorithm: #{algo.inspect}"
        end

        unless algo == "ecdsa-sha2-#{curve}"
          raise DecodeError, "bad curve: #{curve.inspect}"
        end

        @curve = curve
        @public_key_bytes = public_key

        @openssl = begin
          OpenSSL::PKey::EC.new(asn1.to_der)
        rescue ArgumentError
          raise DecodeError, "bad key data"
        end

        super(algo: algo)
      end

      # Verify an SSH signature.
      #
      # signed_data - The String message that the signature was calculated over.
      # signature   - The binarty String signature with SSH encoding.
      #
      # Returns boolean.
      def verify(signed_data, signature)
        sig_algo, ssh_sig, _ = Encoding.decode_signature(signature)
        if sig_algo != "ecdsa-sha2-#{curve}"
          raise DecodeError, "bad signature algorithm: #{sig_algo.inspect}"
        end

        openssl_sig = self.class.openssl_signature(ssh_sig)
        digest = DIGEST_FOR_CURVE[curve]

        openssl.verify(digest.new, openssl_sig, signed_data)
      end

      def ==(other)
        super && other.curve == curve && other.public_key_bytes == public_key_bytes
      end

      private

      def asn1
        unless name = OPENSSL_CURVE_NAME_FOR_CURVE[curve]
          raise DecodeError, "unknown curve: #{curve.inspect}"
        end

        OpenSSL::ASN1::Sequence.new([
          OpenSSL::ASN1::Sequence.new([
            OpenSSL::ASN1::ObjectId.new("id-ecPublicKey"),
            OpenSSL::ASN1::ObjectId.new(name),
          ]),
          OpenSSL::ASN1::BitString.new(public_key_bytes),
        ])
      end
    end
  end
end
