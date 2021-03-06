provider "aws"{
  region = "ap-south-1"
}


resource "tls_private_key" "key" {
  algorithm = "RSA"
}


resource "aws_key_pair" "deployer"{
  key_name = "key1"
  public_key = tls_private_key.key.public_key_openssh  

}


resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }
}


resource "aws_security_group" "my_sg" {
  name        = "my_sg"
  description = "Allow SSH and http"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "http from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}


resource "aws_instance" "os" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.deployer.key_name
  security_groups = [aws_security_group.my_sg.name]

  tags = {
    Name = "project-os"
  }

 provisioner "local-exec" {
  command = "echo ${aws_instance.os.public_ip} > publicIP.txt"
 }
}


resource "aws_ebs_volume" "task1" {
  availability_zone = aws_instance.os.availability_zone
  size              = 1

  tags = {
    Name = "task1"
  }
}


resource "aws_volume_attachment" "ebs_att" {
  depends_on = [aws_ebs_volume.task1]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.task1.id
  instance_id = aws_instance.os.id
  force_detach = true
}


resource "null_resource" "mounting"{
  connection{
    type = "ssh"
    user = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
    host = aws_instance.os.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd php git -y",
      "sudo systemctl enable httpd",
      "sudo systemctl start httpd",
      "sudo mkfs.ext4 ${aws_volume_attachment.ebs_att.device_name}",
      "sudo mount ${aws_volume_attachment.ebs_att.device_name} /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/Yashmb/ec2.instance.git /var/www/html"
    ]
  }  

}


# Creating New Origin Access Identity
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "new-acess-identity"
}


resource "aws_s3_bucket" "task1" {
  bucket = "tf.task1"
  acl    = "public-read"

  tags = {
    Name        = "task1"
  }
}


resource "aws_s3_bucket_policy" "task1_bp" {
  bucket = aws_s3_bucket.task1.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "MYBUCKETPOLICY",
  "Statement": [
    {
      "Sid": "IPAllow",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": "arn:aws:s3:::${aws_s3_bucket.task1.bucket}/*",
      "Condition": {
         "IpAddress": {"aws:SourceIp": "8.8.8.8/32"}
      }
    }
  ]
}
POLICY
}  

resource "aws_s3_bucket_object" "object" {
  acl = "public-read"
  depends_on = [aws_s3_bucket.task1]
  bucket = aws_s3_bucket.task1.id
  key    = "hacker.jpg"
  source = "./hacker.jpg"
}

locals {
  s3_origin_id = "yash-s3"
}


resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.task1.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Cache behavior with precedence 0
  ordered_cache_behavior {
    path_pattern     = "/content/immutable/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 1
  ordered_cache_behavior {
    path_pattern     = "/content/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  price_class = "PriceClass_All"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}



resource "null_resource" "index_file"{
  connection{
    type = "ssh"
    user = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
    host = aws_instance.os.public_ip
  }

provisioner "remote-exec" {
        inline  = [
            "sudo su << EOF",
            "echo \"<img src=\"http://${aws_cloudfront_distribution.s3_distribution.domain_name}/${aws_s3_bucket_object.object.key}\" height=625 width=1350>\" >> /var/www/html/index.html",
            "EOF"
        ]
    }
}

resource "null_resource" "CloudFront_Domain" {
  depends_on = [aws_cloudfront_distribution.s3_distribution]

  provisioner "local-exec" {
    command = "echo ${aws_cloudfront_distribution.s3_distribution.domain_name} > CloudFrontURL.txt" 
  }
}
