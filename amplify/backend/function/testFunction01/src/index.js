

/**
 * @type {import('@types/aws-lambda').APIGatewayProxyHandler}
 */
exports.handler = async (event) => {
    console.log(`EVENT: ${JSON.stringify(event)}`);
    console.log(`test logging from testFunction01`);
    return {
        statusCode: 200,
        body: JSON.stringify('Hello from AWS Lambda!, test change3 new, may be this time this change is not ignored'),
    };
};
