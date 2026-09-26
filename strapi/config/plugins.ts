export default ({ env }) => {
  const bucket = env('AWS_S3_BUCKET');

  if (!bucket) {
    return {};
  }

  return {
    upload: {
      config: {
        provider: 'aws-s3',
        providerOptions: {
          baseUrl: env('AWS_S3_BASE_URL'),
          s3Options: {
            region: env('AWS_REGION'),
            params: {
              Bucket: bucket,
            },
          },
        },
      },
    },
  };
};
